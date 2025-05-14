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
  alias Collector.Workers.ConsoleConnection.EventExtractor

  @timeout_check_interval_ms :timer.seconds(2)
  @inactivity_timeout_ms :timer.seconds(10)

  @type connection_details :: %{
          game_data_cursor: binary(),
          version: String.t(),
          client_token: integer()
        }

  @type command :: byte()
  @type payload_sizes :: %{command() => non_neg_integer()}

  @type game_state :: %{
          game_id: String.t(),
          game_start_time: integer() | nil
        }

  @type state :: %{
          wii: Slippi.WiiConsole.t(),
          socket: :gen_tcp.socket() | nil,
          buffer: binary(),
          replay_buffer: binary(),
          payload_sizes: payload_sizes() | nil,
          active_replay_processor: pid() | nil,
          active_replay_processor_ref: reference() | nil,
          monitored_refs: MapSet.t(reference()),
          connection_details: connection_details(),
          connection_status: :disconnected | :connected | :connecting,
          game_state: game_state() | nil,
          last_message_time: integer()
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
    ConnLogger.info("Starting console connection for #{wii_console.nickname} (#{wii_console.ip})")

    ConnLogger.set_wii_context(wii_console)
    # lookup if the console is already connected. return :already_connected if it is.
    case Registry.lookup(Collector.WiiRegistry, wii_console.mac) do
      [{pid, _state}] ->
        ConnLogger.warning("Console already connected: #{wii_console.nickname} (PID: #{pid})")
        {:stop, :already_connected}

      [] ->
        case Handler.connect(wii_console) do
          {:ok, socket} ->
            initial_connection_details = %{
              game_data_cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
              version: "0.1.0",
              client_token: 0
            }

            {:ok, _} =
              Registry.register(
                Collector.WiiRegistry,
                wii_console.mac,
                %{console: wii_console, connection: self()}
              )

            # schedule the first inactivity check
            Process.send_after(self(), :check_inactivity, @timeout_check_interval_ms)

            {:ok,
             %{
               wii: wii_console,
               socket: socket,
               buffer: <<>>,
               replay_buffer: <<>>,
               payload_sizes: nil,
               active_replay_processor: nil,
               active_replay_processor_ref: nil,
               monitored_refs: MapSet.new(),
               connection_details: initial_connection_details,
               connection_status: :connected,
               last_message_time: System.system_time(:millisecond),
               game_state: nil
             }}

          {:error, reason} ->
            ConnLogger.error("Failed to connect to Wii at #{wii_console.ip}: #{inspect(reason)}")
            {:error, reason}
        end
    end
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
  def handle_info(:check_inactivity, state) do
    idle_time = System.system_time(:millisecond) - state.last_message_time

    if idle_time > @inactivity_timeout_ms do
      ConnLogger.warning("Connection timed out after #{idle_time}ms of inactivity.")
      {:stop, :normal, state}
    else
      Process.send_after(self(), :check_inactivity, @timeout_check_interval_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, :normal},
        %{active_replay_processor_ref: ref} = state
      ) do
    ConnLogger.debug("Replay processor exited: #{inspect(state)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{active_replay_processor_ref: ref} = state
      ) do
    ConnLogger.warning("Replay processor crashed: #{inspect(reason)}")

    updated_state = %{state | active_replay_processor: nil, active_replay_processor_ref: nil}

    {:noreply, updated_state}
  end

  @impl true
  def terminate(reason, state) do
    ConnLogger.info("Terminating connection")
    ConnLogger.debug("Reason: #{inspect(reason)}")
    ConnLogger.debug("State: #{inspect(state)}")

    if reason == :timeout do
      ConnLogger.warning("Connection to #{state.wii.nickname} (#{state.wii.ip}) timed out.")
    end

    # close the socket
    Handler.close(state.socket)
    ConnLogger.debug("Socket closed")

    # remove the socket from the registry
    Registry.unregister(Collector.WiiRegistry, state.wii.mac)
    ConnLogger.debug("Connection removed from registry")
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

    {:ok, new_state}
  end

  @spec handle_replay_message(map(), state()) :: {:ok, state()} | {:error, atom()}
  def handle_replay_message(
        %{"data" => data, "pos" => read_pos, "nextPos" => next_pos, "forcePos" => force_pos},
        state
      ) do
    binary_data = :binary.list_to_bin(data)
    read_pos_binary = :binary.list_to_bin(read_pos)
    next_pos_binary = :binary.list_to_bin(next_pos)

    with {:ok, next_cursor} <-
           validate_cursor(read_pos_binary, next_pos_binary, force_pos, state),
         {:ok, updated_state} <-
           process_replay_message(
             <<state.replay_buffer::binary, binary_data::binary>>,
             put_in(state.connection_details.game_data_cursor, next_cursor)
           ) do
      {:ok, updated_state}
    else
      {:error, :position_mismatch} ->
        {:error, :position_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec process_replay_message(binary(), state()) :: {:ok, state()} | {:error, atom()}
  def process_replay_message(payload, state) do
    updated_state = Map.put(state, :last_message_time, System.system_time(:millisecond))

    case EventExtractor.process_replay_event_data(payload, updated_state) do
      {:payload_sizes, payload_sizes, event_data, rest} ->
        # create a new replay processor
        {:ok, replay_processor} = ReplayProcessor.start_link(state.wii)
        replay_processor_ref = Process.monitor(replay_processor)

        # update the state with the new replay processor, payload sizes, and buffer
        updated_state = %{
          updated_state
          | active_replay_processor: replay_processor,
            active_replay_processor_ref: replay_processor_ref,
            payload_sizes: payload_sizes,
            replay_buffer: rest
        }

        # ingest the payload sizes event
        ReplayProcessor.process_event(replay_processor, event_data)
        process_replay_message(rest, updated_state)

      {:event, command, payload, rest} when not is_nil(state.payload_sizes) ->
        ReplayProcessor.process_event(state.active_replay_processor, <<command::8>> <> payload)
        process_replay_message(rest, updated_state)

      {:continue, rest} ->
        {:ok, %{updated_state | replay_buffer: rest}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_keepalive_message(state) do
    %{state | last_message_time: System.system_time(:millisecond)}
  end

  @spec validate_cursor(binary(), binary(), boolean(), state()) ::
          {:ok, binary()} | {:error, atom()}
  def validate_cursor(read_cursor, next_cursor, force_pos, state) do
    current_cursor = state.connection_details.game_data_cursor

    cond do
      # Force position for overflow handling
      force_pos ->
        {:ok, next_cursor}

      # Normal case - positions match
      current_cursor == read_cursor ->
        {:ok, next_cursor}

      # Initial position
      current_cursor == <<0, 0, 0, 0, 0, 0, 0, 0>> ->
        {:ok, next_cursor}

      # Position mismatch error
      current_cursor != read_cursor ->
        ConnLogger.error(
          "Position mismatch. Expected: #{inspect(current_cursor)}, Got: #{inspect(read_cursor)}"
        )

        {:error, :position_mismatch}
    end
  end
end
