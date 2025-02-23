defmodule Slippi.ConsoleConnection do
  @moduledoc """
  Manages TCP connection to a Wii console running Slippi.
  Handles connection establishment, message sending, and collecting replay data.
  """

  use GenServer
  require Logger
  import Bitwise

  alias Slippi.ConsoleCommunication

  @default_port 51441
  @message_sizes_command 0x35

  @type connection_details :: %{
          game_data_cursor: binary(),
          version: String.t(),
          client_token: integer()
        }

  @type state :: %{
          wii: Slippi.WiiConsole.t(),
          socket: :gen_tcp.socket() | nil,
          buffer: binary(),
          payload_sizes: %{byte() => non_neg_integer()} | nil,
          split_message_buffer: binary() | nil,
          connection_details: connection_details() | nil
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
    Logger.info("Starting console connection for #{wii_console.nickname}")

    # lookup if the console is already connected. return :already_connected if it is.
    case Registry.lookup(Collector.WiiRegistry, wii_console.mac) do
      [{_pid, %{connection: connection}}] ->
        Logger.info("Console already connected: #{wii_console.nickname}")
        {:error, {:already_connected, connection}}

      [] ->
        case connect(wii_console) do
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
               payload_sizes: nil,
               split_message_buffer: nil,
               connection_details: initial_connection_details
             }}

          {:error, reason} ->
            Logger.error("Failed to connect to Wii at #{wii_console.ip}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @impl true
  @spec handle_cast({:send_message, binary()}, state :: state()) :: {:noreply, state()}
  def handle_cast({:send_message, message}, %{socket: socket} = state) when not is_nil(socket) do
    case :gen_tcp.send(socket, message) do
      :ok ->
        Logger.debug("Sent message to Wii at #{state.wii.ip}")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to send message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_message, _message}, state) do
    Logger.warning("Attempted to send message while disconnected")
    {:noreply, state}
  end

  @impl true
  @spec handle_cast(:disconnect, state :: state()) :: {:stop, :normal, state()}
  def handle_cast(:disconnect, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
      Logger.info("Disconnected from Wii at #{state.wii.ip}")
      {:stop, :normal, state}
    else
      Logger.debug("Already disconnected from Wii at #{state.wii.ip}")
      {:stop, :normal, state}
    end
  end

  @impl true
  @spec handle_info({:tcp, :gen_tcp.socket(), binary()}, state :: state()) :: {:noreply, state()}
  def handle_info({:tcp, _socket, data}, state) do
    {messages, new_buffer} = ConsoleCommunication.process_received_data(data, state.buffer)

    # Handle each decoded message and accumulate state changes
    result =
      Enum.reduce_while(messages, {:ok, %{state | buffer: new_buffer}}, fn message,
                                                                           {:ok, acc_state} ->
        case message do
          %ConsoleCommunication.Message{type: type, payload: payload} ->
            case type do
              1 ->
                Logger.debug("Received handshake response")
                {:cont, {:ok, acc_state}}

              2 ->
                case handle_replay_message(payload, acc_state) do
                  {:noreply, new_state} -> {:cont, {:ok, new_state}}
                  {:error, reason} -> {:halt, {:error, reason}}
                end

              3 ->
                {:cont, {:ok, acc_state}}

              _ ->
                Logger.warning("Unknown message type: #{type}")
                {:cont, {:ok, acc_state}}
            end
        end
      end)

    case result do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Error processing message: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("Connection closed by Wii")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("TCP error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  @spec connect(Slippi.WiiConsole.t()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  defp connect(wii_console) do
    case :gen_tcp.connect(
           String.to_charlist(wii_console.ip),
           @default_port,
           [:binary, active: true, packet: :raw]
         ) do
      {:ok, socket} ->
        case send_handshake(socket) do
          :ok ->
            Logger.info("Connected to Wii at #{wii_console.ip}")
            {:ok, socket}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp send_handshake(socket) do
    :gen_tcp.send(
      socket,
      ConsoleCommunication.generate_handshake(<<0, 0, 0, 0, 0, 0, 0, 0>>, 0, false)
    )
  end

  # Handles a replay message from the Wii console.
  #
  # Parameters
  # - `payload`: The payload of the message.
  # - `state`: The current state of the connection.
  #
  # Returns
  # - `{:noreply, state}`: If the message is a complete message.
  @spec handle_replay_message(map(), state :: state()) :: {:noreply, state()}
  defp handle_replay_message(
         %{"data" => data, "pos" => read_pos, "nextPos" => next_pos, "forcePos" => force_pos} =
           _payload,
         state
       )
       when is_list(data) do
    binary_data = :binary.list_to_bin(data)
    read_pos_binary = :binary.list_to_bin(read_pos)
    next_pos_binary = :binary.list_to_bin(next_pos)
    current_cursor = state.connection_details.game_data_cursor

    # Enhanced raw data logging
    Logger.debug("Received replay data: #{byte_size(binary_data)} bytes")
    Logger.debug("Raw data (first 50 bytes): #{inspect(binary_data, limit: 50, base: :hex)}")

    # Scan for important commands in the data
    binary_data
    |> :binary.bin_to_list()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.each(fn {[cmd | _], idx} ->
      case cmd do
        0x35 -> Logger.debug("Found message sizes command at position #{idx}")
        0x36 -> Logger.debug("Found game start command at position #{idx}")
        0x37 -> Logger.debug("Found pre-frame update at position #{idx}")
        0x38 -> Logger.debug("Found post-frame update at position #{idx}")
        0x39 -> Logger.debug("Found game end at position #{idx}")
        _ -> :ok
      end
    end)

    # Log current state
    Logger.debug("Current state:")
    Logger.debug("- Payload sizes: #{inspect(state.payload_sizes)}")
    Logger.debug("- Split message buffer: #{inspect(state.split_message_buffer)}")
    Logger.debug("- Current cursor: #{inspect(current_cursor)}")
    Logger.debug("- Read position: #{inspect(read_pos_binary)}")
    Logger.debug("- Next position: #{inspect(next_pos_binary)}")

    # If this is the first message (cursor is all zeros), accept the position
    is_initial_position = current_cursor == <<0, 0, 0, 0, 0, 0, 0, 0>>

    state =
      cond do
        is_initial_position ->
          Logger.debug("Processing initial position")
          put_in(state.connection_details.game_data_cursor, next_pos_binary)

        force_pos ->
          Logger.warn("Overflow occurred in Nintendont, data may be corrupted")
          put_in(state.connection_details.game_data_cursor, next_pos_binary)

        current_cursor != read_pos_binary ->
          Logger.error(
            "Position mismatch. Expected: #{inspect(current_cursor)}, Got: #{inspect(read_pos_binary)}"
          )

          raise "Position mismatch in replay data"

        true ->
          put_in(state.connection_details.game_data_cursor, next_pos_binary)
      end

    # Process commands and propagate state changes
    process_replay_commands(binary_data, state)
  end

  # Process the commands in the replay data
  defp process_replay_commands("", state) do
    # If we have a split message buffer, try to process it
    case state.split_message_buffer do
      {command, buffer} ->
        Logger.debug(
          "Processing remaining split message buffer for command 0x#{Integer.to_string(command, 16)}"
        )

        try do
          process_replay_commands(<<command, buffer::binary>>, %{
            state
            | split_message_buffer: nil
          })
        catch
          kind, reason ->
            Logger.error(
              "Error processing split message buffer: #{inspect(kind)} #{inspect(reason)}"
            )

            {:error, reason}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp process_replay_commands(<<command, rest::binary>>, state) do
    try do
      # Log raw command data for debugging
      Logger.debug(
        "Raw command data: #{inspect(<<command, rest::binary>>, limit: 20, base: :hex)}"
      )

      # Skip empty or invalid commands
      if command == 0 and byte_size(rest) > 0 do
        Logger.debug("Skipping empty command (0x00), continuing with rest of data")
        process_replay_commands(rest, state)
      else
        # If we have a split message buffer, check if we should continue buffering or process new commands
        {data, command_to_process, should_continue} =
          case state.split_message_buffer do
            nil ->
              Logger.debug(
                "No split message buffer, processing command 0x#{Integer.to_string(command, 16)} (#{command})"
              )

              {rest, command, true}

            {buffered_command, buffer} ->
              Logger.debug(
                "Found split message buffer for command 0x#{Integer.to_string(buffered_command, 16)} (#{buffered_command}) with #{byte_size(buffer)} bytes"
              )

              # Get the expected size for this command
              expected_size = Map.get(state.payload_sizes, buffered_command)
              combined_data = <<buffer::binary, command, rest::binary>>

              Logger.debug(
                "Combined data size: #{byte_size(combined_data)}/#{expected_size} bytes"
              )

              # If the combined data is still smaller than what we need, keep buffering
              if byte_size(combined_data) < expected_size do
                Logger.debug(
                  "Still need more data for command 0x#{Integer.to_string(buffered_command, 16)}"
                )

                {combined_data, buffered_command, true}
              else
                # We have enough data, extract what we need and continue with the rest
                <<needed::binary-size(expected_size), remaining::binary>> = combined_data

                Logger.debug(
                  "Have enough data for command 0x#{Integer.to_string(buffered_command, 16)}, continuing with remaining #{byte_size(remaining)} bytes"
                )

                # Process the complete command first
                state = process_complete_command(buffered_command, needed, state)

                # Then continue with the remaining data as a new command
                case remaining do
                  <<next_cmd, next_rest::binary>> when next_cmd != 0 ->
                    Logger.debug(
                      "Next command in remaining data: 0x#{Integer.to_string(next_cmd, 16)} (#{next_cmd})"
                    )

                    {next_rest, next_cmd, true}

                  <<0, more_rest::binary>> when byte_size(more_rest) > 0 ->
                    Logger.debug("Found padding (0x00) in remaining data, skipping")
                    process_replay_commands(more_rest, state)

                  _ ->
                    {remaining, command, false}
                end
              end

            _ ->
              Logger.debug("Invalid split message buffer state")
              {rest, command, true}
          end

        if should_continue do
          # Log the command we're about to process for debugging
          Logger.debug(
            "Processing command: 0x#{Integer.to_string(command_to_process, 16)} (#{command_to_process}) with #{byte_size(data)} bytes of data"
          )

          case command_to_process do
            # Message sizes command - must be first command
            @message_sizes_command ->
              case data do
                <<payload_len, rest::binary>> when payload_len > 0 ->
                  case process_message_sizes(<<payload_len, rest::binary>>) do
                    {:ok, sizes, remaining} when map_size(sizes) > 0 ->
                      # Convert decimal keys to hex for easier debugging
                      hex_sizes =
                        Enum.map(sizes, fn {k, v} -> {"0x#{Integer.to_string(k, 16)}", v} end)
                        |> Enum.into(%{})

                      Logger.debug("Received message sizes: #{inspect(hex_sizes)}")
                      # Store sizes in state and continue processing with clean buffer
                      state = %{state | payload_sizes: sizes, split_message_buffer: nil}
                      process_replay_commands(remaining, state)

                    {:ok, _empty_sizes, remaining} ->
                      Logger.debug("Keeping existing payload sizes")
                      process_replay_commands(remaining, state)

                    {:error, reason} ->
                      Logger.warning("Failed to process message sizes: #{inspect(reason)}")
                      {:error, reason}
                  end

                _ ->
                  Logger.warning("Invalid message sizes data")
                  {:error, :invalid_message_sizes}
              end

            # For all other commands, only process if we have payload sizes
            _ when is_nil(state.payload_sizes) or map_size(state.payload_sizes) == 0 ->
              Logger.debug(
                "No valid payload sizes yet, skipping command #{inspect(command_to_process, base: :hex)} (decimal: #{command_to_process})"
              )

              process_replay_commands(data, state)

            # Any command with a known size
            _ ->
              case Map.get(state.payload_sizes, command_to_process) do
                nil ->
                  # If we don't know this command's size, skip it and continue with the rest
                  Logger.debug(
                    "Unknown command #{inspect(command_to_process, base: :hex)} (decimal: #{command_to_process}), skipping"
                  )

                  process_replay_commands(data, state)

                size ->
                  case data do
                    <<command_data::binary-size(size), remaining::binary>> ->
                      # Successfully processed command, clear buffer and continue
                      Logger.debug(
                        "Successfully processed command #{inspect(command_to_process, base: :hex)} (decimal: #{command_to_process}, #{size} bytes)"
                      )

                      state = process_complete_command(command_to_process, command_data, state)
                      process_replay_commands(remaining, state)

                    incomplete_data ->
                      # Store incomplete data in buffer for next message
                      Logger.debug(
                        "Incomplete data for command #{inspect(command_to_process, base: :hex)} (decimal: #{command_to_process}, #{byte_size(incomplete_data)}/#{size} bytes), buffering"
                      )

                      {:noreply,
                       %{state | split_message_buffer: {command_to_process, incomplete_data}}}
                  end
              end
          end
        else
          {:noreply, state}
        end
      end
    catch
      kind, reason ->
        Logger.error("Error processing command: #{inspect(kind)} #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Helper function to process a complete command
  defp process_complete_command(command, command_data, state) do
    case command do
      # Game start command (decimal 54 = 0x36)
      54 ->
        Logger.debug("Processing complete game start command")

        case command_data do
          <<version::binary-size(4), game_info_block::binary-size(312), random_seed::32,
            dash_back_fix::8, shield_drop_fix::8, rest::binary>> ->
            Logger.info("Game Start Event received:")
            Logger.info("- Raw Version: #{inspect(version)}")
            Logger.info("- Random Seed: #{random_seed}")
            Logger.info("- Dash Back Fix: #{dash_back_fix}")
            Logger.info("- Shield Drop Fix: #{shield_drop_fix}")
            Logger.info("- Remaining data size: #{byte_size(rest)} bytes")

            # Parse game info block
            <<game_bitfield1::8, game_bitfield2::8, game_bitfield3::8, game_bitfield4::8,
              bomb_rain::8, item_spawn_bitfield::8, self_destruct_score_value::8, stage::16,
              game_timer::32, item_spawn_bitfield2::8, item_spawn_bitfield3::8,
              item_spawn_bitfield4::8, item_spawn_bitfield5::8, damage_ratio::32,
              rest_game_info::binary>> = game_info_block

            Logger.info("Game Info:")
            Logger.info("- Stage ID: #{stage}")
            Logger.info("- Timer: #{game_timer} frames")
            Logger.info("- Damage Ratio: #{damage_ratio / 100.0}")
            Logger.info("- Bomb Rain: #{bomb_rain}")

            game_settings = %{
              is_teams: (game_bitfield1 &&& 0x01) != 0,
              is_stock: (game_bitfield1 &&& 0x10) != 0,
              timer_running: (game_bitfield3 &&& 0x80) != 0
            }

            Logger.info("- Game Settings: #{inspect(game_settings)}")

            Logger.info(
              "- Game Bitfields: #{inspect(%{bitfield1: game_bitfield1, bitfield2: game_bitfield2, bitfield3: game_bitfield3, bitfield4: game_bitfield4}, base: :hex)}"
            )

            items_enabled =
              item_spawn_bitfield != 0 or item_spawn_bitfield2 != 0 or
                item_spawn_bitfield3 != 0 or item_spawn_bitfield4 != 0 or
                item_spawn_bitfield5 != 0

            Logger.info("- Items Enabled: #{items_enabled}")

            Logger.info(
              "- Item Spawn Bitfields: #{inspect(%{bitfield1: item_spawn_bitfield, bitfield2: item_spawn_bitfield2, bitfield3: item_spawn_bitfield3, bitfield4: item_spawn_bitfield4, bitfield5: item_spawn_bitfield5}, base: :hex)}"
            )

            Logger.info("- Self Destruct Score: #{self_destruct_score_value}")
            Logger.info("- Game Info Block remaining: #{byte_size(rest_game_info)} bytes")

          _ ->
            Logger.warning("Invalid game start data format")
            Logger.warning("Data size: #{byte_size(command_data)} bytes")
        end

      # Other commands just get logged
      _ ->
        Logger.debug("Processed command 0x#{Integer.to_string(command, 16)} (#{command})")
    end

    %{state | split_message_buffer: nil}
  end

  defp process_message_sizes(<<payload_len, data::binary>>) do
    Logger.debug("Processing message sizes payload with length #{payload_len}")

    try do
      case process_message_size_entries(data, payload_len, %{}) do
        {:ok, sizes, rest} ->
          # Log each command size individually for better debugging
          Enum.each(sizes, fn {cmd, size} ->
            Logger.debug("Command 0x#{Integer.to_string(cmd, 16)} (#{cmd}) size: #{size} bytes")
          end)

          # Keep only the last occurrence of each command size
          unique_sizes =
            Enum.reduce(sizes, %{}, fn {cmd, size}, acc ->
              Map.put(acc, cmd, size)
            end)

          Logger.debug("Final command sizes after deduplication: #{inspect(unique_sizes)}")

          {:ok, unique_sizes, rest}

        {:error, reason} ->
          Logger.warning("Failed to process message sizes: #{reason}")
          {:error, reason}
      end
    catch
      kind, reason ->
        Logger.warning("Error processing message sizes: #{inspect(kind)} #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_message_size_entries(rest, 0, acc), do: {:ok, acc, rest}

  defp process_message_size_entries(<<cmd, size::16, rest::binary>>, remaining, acc)
       when remaining > 0 do
    Logger.debug("Processing size entry: command 0x#{Integer.to_string(cmd, 16)} (#{cmd})")
    process_message_size_entries(rest, remaining - 1, Map.put(acc, cmd, size))
  end

  defp process_message_size_entries(data, remaining, acc) do
    Logger.warning(
      "Invalid message size data format. Remaining: #{remaining}, Data size: #{byte_size(data)}"
    )

    {:error, :invalid_data}
  end
end
