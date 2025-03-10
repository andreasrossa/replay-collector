defmodule Slippi.ConsoleConnection do
  @moduledoc """
  Manages TCP connection to a Wii console running Slippi.
  Handles connection establishment, message sending, and collecting replay data.
  """

  use GenServer

  alias Slippi.ConsoleCommunication
  alias Slippi.Connection.Handler
  alias Slippi.Connection.ReplayProcessor
  alias Slippi.Connection.Logger, as: ConnLogger

  @type connection_details :: %{
          game_data_cursor: binary(),
          version: String.t(),
          client_token: integer()
        }

  @type metadata :: %{
          consoleNickname: String.t() | nil,
          startTime: DateTime.t() | nil,
          lastFrame: integer() | nil,
          game_settings: map() | nil
        }

  @type command :: byte()
  @type payload_sizes :: %{command() => non_neg_integer()}
  @type state :: %{
          wii: Slippi.WiiConsole.t(),
          socket: :gen_tcp.socket() | nil,
          buffer: binary(),
          message_buffer: binary(),
          payload_sizes: payload_sizes() | nil,
          split_message_buffer: binary() | nil,
          connection_details: connection_details() | nil,
          metadata: metadata()
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
  Sends a message to the console.
  ## Parameters
  - `pid`: The PID of the console connection.
  - `message`: The message to send.
  ## Returns
  - `:ok`: If the message is sent successfully.
  """
  @spec send_message(atom() | pid() | {atom(), any()} | {:via, atom(), any()}, any()) :: :ok
  def send_message(pid, message) do
    GenServer.cast(pid, {:send_message, message})
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
      [{_pid, %{connection: connection}}] ->
        ConnLogger.warning("Console already connected: #{wii_console.nickname}")
        {:error, {:already_connected, connection}}

      [] ->
        case Handler.connect(wii_console) do
          {:ok, socket} ->
            initial_connection_details = %{
              game_data_cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
              version: "0.1.0",
              client_token: 0
            }

            {:ok,
             %{
               wii: wii_console,
               socket: socket,
               buffer: <<>>,
               message_buffer: <<>>,
               payload_sizes: nil,
               split_message_buffer: nil,
               metadata: %{
                 consoleNickname: nil,
                 startTime: nil,
                 lastFrame: nil,
                 game_settings: nil
               },
               connection_details: initial_connection_details
             }}

          {:error, reason} ->
            ConnLogger.error("Failed to connect to Wii at #{wii_console.ip}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @impl true
  @spec handle_cast({:send_message, binary()}, state :: state()) :: {:noreply, state()}
  def handle_cast({:send_message, message}, %{socket: socket} = state) when not is_nil(socket) do
    case Handler.send_message(socket, message) do
      :ok ->
        ConnLogger.debug("Sent message to Wii: #{inspect(message)}")
        {:noreply, state}

      {:error, reason} ->
        ConnLogger.error("Failed to send message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_message, _message}, state) do
    ConnLogger.warning("Attempted to send message while disconnected")
    {:noreply, state}
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
        %{buffer: buffer, message_buffer: message_buffer} = state
      ) do
    {messages, new_buffer} = ConsoleCommunication.process_received_data(data, buffer)

    # Handle each decoded message and accumulate state changes
    result =
      Enum.reduce_while(messages, {:ok, %{state | buffer: new_buffer}}, fn message,
                                                                           {:ok, acc_state} ->
        case message do
          %ConsoleCommunication.Message{type: type, payload: payload} ->
            case type do
              1 ->
                # set metadata
                new_state =
                  put_in(acc_state.connection_details.version, payload["nintendontVersion"])

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

                {:cont, {:ok, new_state}}

              2 ->
                case ReplayProcessor.handle_replay_message(payload, acc_state, message_buffer) do
                  {:ok, new_state, new_message_buffer} ->
                    {:cont, {:ok, %{new_state | message_buffer: new_message_buffer}}}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end

              3 ->
                {:cont, {:ok, acc_state}}

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
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    Handler.close(state.socket)
    ConnLogger.debug("Terminating connection: #{inspect(state)}")
    :ok
  end
end
