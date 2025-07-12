defmodule Collector.Workers.ConsoleConnection.ReplayManager do
  @moduledoc """
  Keeps **logical** state for a Wii connection.

  • authoritative cursor
  • payload_sizes (after 0x35 event)
  • current ReplaySession pid / monitor
  • parses handshake / replay messages and
    decides when to spawn, forward to, or
    finalize a ReplaySession.
  """

  use GenServer

  alias Collector.Utils.ConsoleLogger, as: ConnLogger
  alias Collector.Workers.ConsoleConnection.EventExtractor
  alias Collector.Workers.ReplaySessionSupervisor, as: SessionSup
  alias Collector.Workers.ReplaySession
  alias Slippi.WiiConsole

  # -----------------------------------------------------------------------------
  # State
  # -----------------------------------------------------------------------------

  defmodule State do
    @enforce_keys [:wii]
    defstruct wii: nil,
              cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
              payload_sizes: nil,
              buffer: <<>>,
              current_session: nil,
              current_session_ref: nil,
              status: :idle

    @type t :: %__MODULE__{
            wii: WiiConsole.t(),
            cursor: binary(),
            payload_sizes: %{byte() => non_neg_integer()} | nil,
            buffer: binary(),
            current_session: pid() | nil,
            current_session_ref: reference() | nil,
            status: :idle | :active
          }
  end

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------

  def start_link(wii) do
    GenServer.start_link(__MODULE__, wii, name: via_tuple(wii.mac))
  end

  def deliver_message(pid, message, cursor), do: GenServer.cast(pid, {:msg, message, cursor})

  @spec get_cursor(pid()) :: binary()
  def get_cursor(pid), do: GenServer.call(pid, :get_cursor)

  # -----------------------------------------------------------------------------
  # Server Callbacks
  # -----------------------------------------------------------------------------

  @impl true
  def init(%WiiConsole{} = wii) do
    {:ok, %State{wii: wii}}
  end

  # --------------------- synchronous callbacks ----------------------------------

  @impl true
  def handle_call(:get_cursor, _from, %State{} = state) do
    {:reply, state.cursor, state}
  end

  # --------------------- asynchronous callbacks ----------------------------------

  @impl true
  def handle_cast({:msg, message}, %State{} = state) do
    case EventExtractor.process_replay_event_data(message, state.payload_sizes) do
      {:payload_sizes, payload_sizes, event_data, rest} ->
        {:noreply, create_new_session(payload_sizes, event_data, rest, state)}

      {:event, _cmd, event_data, rest} ->
        forward_to_session(state.current_session, event_data)
        {:noreply, %State{state | buffer: rest}}

      {:continue, rest} ->
        {:noreply, %State{state | buffer: rest}}

      {:error, reason} ->
        ConnLogger.error("Error processing replay message: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  # --------------------- termination callbacks ----------------------------------

  @impl true
  def terminate(reason, state) do
    ConnLogger.debug("ReplayManager terminating: #{inspect(reason)}",
      pid: self()
    )

    :ok
  end

  # --------------------- DOWN from ReplaySession ----------------------------------

  @impl true
  def handle_info(
        {:DOWN, state.current_session_ref, :process, state.current_session, :normal},
        %State{} = state
      ) do
    ConnLogger.debug("ReplaySession terminated normally", session_pid: state.current_session)

    {:noreply,
     %State{
       state
       | status: :idle,
         current_session: nil,
         current_session_ref: nil,
         cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
         payload_sizes: nil
     }}
  end

  @impl true
  def handle_info(
        {:DOWN, state.current_session_ref, :process, state.current_session, reason},
        %State{} = state
      ) do
    ConnLogger.error("ReplaySession terminated abnormally",
      session_pid: state.current_session,
      reason: reason
    )

    {:noreply,
     %State{
       state
       | status: :idle,
         current_session: nil,
         current_session_ref: nil,
         cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
         payload_sizes: nil
     }}
  end

  # -----------------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------------

  defp create_new_session(payload_sizes, event_data, rest, %State{} = state) do
    {:ok, pid} = SessionSup.start_session()
    ref = Process.monitor(pid)

    ConnLogger.debug("Created new ReplaySession", session_pid: pid, pid: self())

    forward_to_session(pid, event_data)

    %State{
      state
      | payload_sizes: payload_sizes,
        buffer: rest,
        current_session: pid,
        current_session_ref: ref,
        cursor: nil,
        status: :active
    }
  end

  defp forward_to_session(pid, event_data) do
    ReplaySession.process_event(pid, event_data)
  end

  defp via_tuple(mac), do: {:via, Registry, {Collector.SessionRegistry, {:mgr, mac}}}
end
