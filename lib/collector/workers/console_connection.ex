defmodule Collector.Workers.ConsoleConnection do
  @moduledoc """
  Manages TCP connection to a Wii console running Slippi.
  Handles connection establishment, message sending, and collecting replay data.
  """

  use GenServer

  alias Collector.Workers.ConsoleConnection.Communication, as: ConsoleCommunication
  alias Collector.Workers.ConsoleConnection.Handler
  alias Collector.Workers.ReplayProcessor
  alias Collector.Utils.ConsoleLogger, as: ConnLogger

  @type connection_details :: %{
          game_data_cursor: binary(),
          version: String.t(),
          client_token: integer()
        }

  @type command :: byte()
  @type payload_sizes :: %{command() => non_neg_integer()}
  @type state :: %{
          wii: Slippi.WiiConsole.t(),
          socket: :gen_tcp.socket() | nil,
          buffer: binary(),
          replay_processor: pid(),
          replay_processor_ref: reference(),
          connection_details: connection_details(),
          connection_status: :disconnected | :connected | :connecting,
          last_keepalive: integer()
        }

  ##############
  # CLIENT API #
  ##############

  @doc """
  Starts a new connection to a Wii console.
  ## Parameters
  - `wii_console`: The Wii console to connect to.
  ## Returns
  - `{:ok, pid}`: The PID of the new connection process.
  - `{:error, {:already_connected, pid}}`: If the console is already connected.
  - `{:error, reason}`: If the connection fails.
  """
  @spec start_link(Slippi.WiiConsole.t()) ::
          {:ok, pid()} | {:error, {:already_connected, pid()} | term()}
  def start_link(wii_console) do
    GenServer.start_link(__MODULE__, wii_console)
  end

  @doc """
  Disconnects from the Wii console.
  ## Parameters
  - `pid`: The PID of the console connection.
  """
  @spec disconnect(atom() | pid() | {atom(), any()} | {:via, atom(), any()}) :: :ok
  def disconnect(pid) do
    GenServer.cast(pid, :disconnect)
  end

  ####################
  # SERVER CALLBACKS #
  ####################

  @doc """
  Initializes the console connection.
  ## Parameters
  - `wii_console`: The Wii console to connect to.
  ## Returns
  - `{:ok, state}`: If the connection is successful.
  - `{:error, {:already_connected, pid}}`: If the console is already connected.
  - `{:error, reason}`: If the connection fails for any other reason.
  """
  @impl true
  @spec init(Slippi.WiiConsole.t()) ::
          {:ok, state()} | {:error, {:already_connected, pid()} | term()}
  def init(wii_console) do
    ConnLogger.debug("Starting console connection")

    ConnLogger.set_wii_context(wii_console)
    # lookup if the console is already connected. return :already_connected if it is.
    case Registry.lookup(Collector.WiiRegistry, wii_console.mac) do
      [{_pid, _state}] ->
        ConnLogger.warning("Console already connected: #{wii_console.nickname}")
        {:stop, :already_connected}

      [] ->
        case Handler.connect(wii_console) do
          {:ok, socket} ->
            initial_connection_details = %{
              game_data_cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
              version: "0.1.0",
              client_token: 0
            }

            # create a new replay processor
            {:ok, replay_processor} = ReplayProcessor.start_link(wii_console)
            replay_processor_ref = Process.monitor(replay_processor)

            {:ok,
             %{
               wii: wii_console,
               socket: socket,
               buffer: <<>>,
               replay_processor: replay_processor,
               connection_details: initial_connection_details,
               connection_status: :connected,
               last_message_time: System.system_time(:millisecond),
               replay_processor_ref: replay_processor_ref
             }}

          {:error, reason} ->
            ConnLogger.error("Failed to connect to Wii at #{wii_console.ip}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @impl true
  @spec handle_cast(:disconnect, state :: state()) :: {:stop, :normal, state()}
  def handle_cast(:disconnect, state) do
    Handler.close(state.socket)
    ConnLogger.info("Disconnected from Wii")
    {:stop, :normal, state}
  end

  @impl true
  @spec handle_info({:tcp, :gen_tcp.socket(), binary()}, state :: state()) :: {:noreply, state()}
  def handle_info(
        {:tcp, _socket, data},
        %{buffer: buffer} = state
      )
      when is_binary(data) do
    {messages, new_buffer} = ConsoleCommunication.process_received_data(data, buffer)

    # Handle each decoded message and accumulate state changes
    result =
      Enum.reduce_while(messages, {:ok, %{state | buffer: new_buffer}}, fn message,
                                                                           {:ok, acc_state} ->
        case message do
          %ConsoleCommunication.Message{type: type, payload: payload} ->
            case type do
              # Handshake
              1 ->
                case handle_handshake_message(payload, acc_state) do
                  {:ok, new_state} ->
                    {:cont, {:ok, new_state}}
                end

              # Replay messages
              2 ->
                case handle_replay_message(payload, acc_state) do
                  {:ok, new_state} ->
                    {:cont, {:ok, new_state}}
                end

              # Keepalive
              3 ->
                {:cont, {:ok, handle_keepalive_message(acc_state)}}

              _ ->
                ConnLogger.warning("Unknown message type: #{type}")
                {:cont, {:ok, acc_state}}
            end
        end
      end)

    case result do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        ConnLogger.error("Error processing message: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    ConnLogger.info("Connection closed by Wii")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    ConnLogger.error("TCP error: #{inspect(reason)}")
    Handler.close(state.socket)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{replay_processor_ref: ref} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{replay_processor_ref: ref} = state) do
    ConnLogger.warning("Replay processor crashed: #{inspect(reason)}")

    # restart replay processor
    {:ok, replay_processor} = ReplayProcessor.start_link(state.wii)
    replay_processor_ref = Process.monitor(replay_processor)

    {:noreply,
     %{state | replay_processor: replay_processor, replay_processor_ref: replay_processor_ref}}
  end

  @impl true
  def terminate(_reason, state) do
    ConnLogger.info("Terminating connection: #{inspect(state)}")
    Handler.close(state.socket)
    :ok
  end

  defp handle_handshake_message(payload, state) do
    new_state =
      put_in(state.connection_details.version, payload["nintendontVersion"])

    client_token = :binary.list_to_bin(payload["clientToken"])
    client_token = :binary.decode_unsigned(client_token, :big)

    new_state =
      put_in(new_state.connection_details.client_token, client_token)

    # set game data cursor
    new_state =
      put_in(
        new_state.connection_details.game_data_cursor,
        :binary.list_to_bin(payload["pos"])
      )

    ConnLogger.debug("Handshake message received: #{inspect(new_state)}")

    {:ok, new_state}
  end

  defp handle_replay_message(payload, state) do
    ReplayProcessor.process_message(state.replay_processor, payload)

    {:ok, %{state | last_message_time: System.system_time(:millisecond)}}
  end

  defp handle_keepalive_message(state) do
    %{state | last_message_time: System.system_time(:millisecond)}
  end
end
