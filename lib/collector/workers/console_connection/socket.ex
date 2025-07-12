defmodule Collector.Workers.ConsoleConnection.Socket do
  @moduledoc """
  A GenServer that manages the socket connection to the console.
  It is responsible for:
  - Performing the initial handshake with the console
  - Receiving data from the console
  - Parsing the data received from the console
  - Sending the parsed data to the replay session manager
  """

  use GenServer
  alias Collector.Workers.ConsoleConnection.Handler
  alias Collector.Workers.ConsoleConnection.Communication, as: Comms
  alias Collector.Utils.ConsoleLogger, as: ConnLogger
  alias Slippi.WiiConsole
  alias Collector.Workers.ConsoleConnection.ReplayManager

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------

  @spec start_link(wii :: WiiConsole.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def get_cursor(pid) do
    GenServer.call(pid, :get_cursor)
  end

  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  # -----------------------------------------------------------------------------
  # State
  # -----------------------------------------------------------------------------

  @timeout_check_interval_ms 2_000
  @inactivity_ms 15_000

  @type socket_details :: %{
          clientToken: binary(),
          nintendontVersion: binary()
        }

  defmodule State do
    @enforce_keys [:wii, :manager_pid]
    defstruct wii: nil,
              socket: nil,
              manager_pid: nil,
              buffer: <<>>,
              last_msg_ts: 0,
              status: :pending,
              socket_details: nil

    @type t :: %__MODULE__{
            wii: WiiConsole.t(),
            socket: :gen_tcp.socket() | nil,
            manager_pid: pid(),
            buffer: binary(),
            last_msg_ts: integer(),
            status: :pending | :handshake | :connected,
            socket_details: socket_details() | nil
          }
  end

  # -----------------------------------------------------------------------------
  # Server Callbacks
  # -----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    %WiiConsole{mac: mac} = wii = Keyword.fetch!(opts, :wii)

    [{manager_pid, _}] = Registry.lookup(Collector.SessionRegistry, {:mgr, mac})

    ConnLogger.set_wii_context(wii)

    state = %State{
      wii: wii,
      socket: nil,
      manager_pid: manager_pid,
      buffer: <<>>,
      last_msg_ts: System.monotonic_time(:millisecond),
      status: :pending,
      socket_details: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  # -----------------------------------------------------------------------------
  # New Connection Handler
  # -----------------------------------------------------------------------------

  @impl true
  def handle_continue(:connect, %State{} = state) do
    cursor = ReplayManager.get_cursor(state.manager_pid)

    case Handler.connect(state.wii) do
      {:ok, socket} ->
        Handler.send_handshake(socket, cursor)
        Process.send_after(self(), :check_timeout, @timeout_check_interval_ms)
        {:noreply, %State{state | socket: socket, status: :handshake}}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  # -----------------------------------------------------------------------------
  # TCP Callbacks
  # -----------------------------------------------------------------------------

  # ------------------- TCP Data -------------------------------------------------

  @impl true
  def handle_info({:tcp, _socket, data}, %State{buffer: buffer} = state) do
    now = now_ms()
    Process.send_after(self(), :check_timeout, @timeout_check_interval_ms)

    {messages, new_buffer} = Comms.process_received_data(data, buffer)

    result =
      Enum.reduce_while(
        messages,
        {:ok, %State{state | last_msg_ts: now, buffer: new_buffer}},
        fn msg, {:ok, acc} ->
          case handle_console_message(msg, acc) do
            {:ok, new_state} ->
              {:cont, {:ok, new_state}}

            {:error, reason} ->
              {:halt, {:error, reason, acc}}
          end
        end
      )

    case result do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason, new_state} ->
        {:stop, reason, new_state}
    end
  end

  # ------------------- TCP Closed -----------------------------------------------

  @impl true
  def handle_info({:tcp_closed, _socket}, %State{} = state) do
    {:stop, :tcp_closed, state}
  end

  # -----------------------------------------------------------------------------
  # Callbacks
  # -----------------------------------------------------------------------------

  @impl true
  def handle_call(:get_cursor, _from, %State{cursor: cursor} = state) do
    {:reply, cursor, state}
  end

  @impl true
  def handle_call(:get_status, _from, %State{status: status} = state) do
    {:reply, status, state}
  end

  # -----------------------------------------------------------------------------
  # Console Message Handlers
  # -----------------------------------------------------------------------------

  # 0x01 - Handshake
  # 0x02 - Replay

  # ------------------- Handshake ------------------------------------------------

  defp handle_console_message(%Comms.Message{type: 1, payload: payload}, %State{} = state) do
    clientToken = payload["clientToken"] |> :binary.list_to_bin() |> :binary.decode_unsigned(:big)
    nintendontVersion = payload["nintendontVersion"] |> :binary.list_to_bin()
    pos = get_cursor(payload)

    ConnLogger.debug("Handshake received: #{inspect({clientToken, nintendontVersion, pos})}")

    cursor = ReplayManager.get_cursor(state.manager_pid)

    if cursor != pos do
      ConnLogger.error("Cursor mismatch: #{inspect(cursor)} != #{inspect(pos)}")
      {:error, :cursor_mismatch}
    end

    {:ok,
     %State{
       state
       | status: :connected,
         socket_details: %{
           clientToken: clientToken,
           nintendontVersion: nintendontVersion
         }
     }}
  end

  # ------------------- Replay ---------------------------------------------------

  defp handle_console_message(
         %Comms.Message{type: 2, payload: payload},
         %State{status: :connected} = state
       ) do
    ReplayManager.deliver_message(state.manager_pid, payload, get_cursor(payload))
    {:ok, state}
  end

  # ------------------- Error Cases ----------------------------------------------

  defp handle_console_message(%Comms.Message{type: 2, payload: payload}, %State{} = _state) do
    ConnLogger.error("Replay message received before handshake: #{inspect(payload)}")
    {:error, :replay_message_before_handshake}
  end

  defp handle_console_message(msg, %State{} = _state) do
    ConnLogger.error("Unknown message type: #{inspect(msg.type)}")
    {:error, :unknown_message_type}
  end

  # -----------------------------------------------------------------------------
  # Timeout Handler
  # -----------------------------------------------------------------------------

  @impl true
  def handle_info(:check_timeout, %State{} = state) do
    if now_ms() - state.last_msg_ts > @inactivity_ms do
      ConnLogger.warning("Inactivity timeout")
      {:stop, :inactivity_timeout, state}
    else
      Process.send_after(self(), :check_timeout, @timeout_check_interval_ms)
      {:noreply, state}
    end
  end

  # -----------------------------------------------------------------------------
  # Terminate Callback
  # -----------------------------------------------------------------------------

  @impl true
  def terminate(reason, %State{} = state) do
    ConnLogger.debug("Console connection terminated: #{inspect(reason)}")
    Handler.close(state.socket)
    :ok
  end

  # -----------------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------------

  defp get_cursor(payload) do
    payload["pos"] |> :binary.list_to_bin()
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
