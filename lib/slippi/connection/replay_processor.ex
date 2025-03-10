defmodule Slippi.Connection.ReplayProcessor do
  @moduledoc """
  Processes replay data and events from Slippi connections.
  """
  alias Slippi.ConsoleConnection
  alias Slippi.Connection.Logger, as: ConnLogger
  require Logger

  @network_message "HELO\0"

  @doc """
  Handles a replay message containing game data.
  """
  @spec handle_replay_message(map(), ConsoleConnection.state(), binary()) ::
          {:ok, ConsoleConnection.state(), binary()} | {:error, atom()}
  def handle_replay_message(
        %{"data" => data, "pos" => read_pos, "nextPos" => next_pos, "forcePos" => force_pos},
        state,
        buffer
      ) do
    binary_data = :binary.list_to_bin(data)
    read_pos_binary = :binary.list_to_bin(read_pos)
    next_pos_binary = :binary.list_to_bin(next_pos)
    current_cursor = state.connection_details.game_data_cursor

    # Handle cursor positions
    result =
      cond do
        # Initial position
        current_cursor == <<0, 0, 0, 0, 0, 0, 0, 0>> ->
          updated_state = put_in(state.connection_details.game_data_cursor, next_pos_binary)
          {:ok, updated_state}

        # Force position for overflow handling
        force_pos ->
          updated_state = put_in(state.connection_details.game_data_cursor, next_pos_binary)
          {:ok, updated_state}

        # Position mismatch error
        current_cursor != read_pos_binary ->
          ConnLogger.error(
            "Position mismatch. Expected: #{inspect(current_cursor)}, Got: #{inspect(read_pos_binary)}"
          )

          {:error, :position_mismatch}

        # Normal case - positions match
        current_cursor == read_pos_binary ->
          updated_state = put_in(state.connection_details.game_data_cursor, next_pos_binary)
          {:ok, updated_state}
      end

    case result do
      {:ok, updated_state} ->
        case process_replay_event_data(<<buffer::binary, binary_data::binary>>, updated_state) do
          {:ok, updated_state, rest} ->
            {:ok, updated_state, rest}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Processes different types of replay events based on command byte.
  """
  @spec process_replay_event_data(binary(), ConsoleConnection.state()) ::
          {:ok, ConsoleConnection.state(), binary()} | {:error, atom()}
  def process_replay_event_data(
        <<@network_message, rest::binary>>,
        state
      ) do
    {:ok, state, rest}
  end

  def process_replay_event_data(<<>>, state) do
    {:ok, state, <<>>}
  end

  def process_replay_event_data(
        <<0x35, payload_len::unsigned-integer-size(8), payload::binary>> = data,
        state
      )
      when payload_len > 0 and byte_size(payload) >= payload_len - 1 do
    <<payload::binary-size(payload_len - 1), rest::binary>> = payload

    Logger.debug(
      "Processing message sizes event. expected size: #{payload_len}, actual payload size: #{byte_size(payload)}, total size: #{byte_size(data)}"
    )

    try do
      payload_sizes =
        Slippi.Connection.MessageSizesParser.process_message_sizes(payload, payload_len)

      ConnLogger.debug("Payload sizes: #{inspect(payload_sizes)}")
      updated_state = %{state | payload_sizes: payload_sizes}
      process_replay_event_data(rest, updated_state)
    catch
      error ->
        ConnLogger.error("Error processing message sizes event: #{inspect(error)}")
        {:error, :message_sizes_parsing_error}
    end
  end

  def process_replay_event_data(
        <<command::unsigned-integer-size(8), payload::binary>> = data,
        state
      )
      when is_map_key(state.payload_sizes, command) and byte_size(payload) > 0 do
    payload_len = state.payload_sizes[command]

    if byte_size(data) < payload_len do
      Logger.debug(
        "Not enough data to process command: #{command} (expected size: #{payload_len}, actual size: #{byte_size(data)})"
      )

      {:ok, state, data}
    end

    <<payload::binary-size(payload_len), rest::binary>> = payload
    {:ok, updated_state} = process_replay_event(<<command, payload::binary>>, state)
    process_replay_event_data(rest, updated_state)
  end

  def process_replay_event_data(
        <<command::unsigned-integer-size(8), payload::binary>> = rest,
        state
      ) do
    ConnLogger.warning("Command not found: #{command} (payload size: #{byte_size(payload)})")
    ConnLogger.warning("Rest: #{inspect(rest)}")
    {:ok, state, rest}
  end

  @spec process_replay_event(binary(), ConsoleConnection.state()) ::
          {:ok, ConsoleConnection.state()} | {:error, atom()}
  def process_replay_event(
        <<0x36, payload::binary>>,
        state
      ) do
    # Parse player data from the game start payload
    {:ok, game_settings} =
      Slippi.Parser.MetadataParser.parse_game_start(<<0x36, payload::binary>>)

    ConnLogger.info("New game started on stage #{game_settings.stage_id}")

    updated_state = %{state | metadata: %{state.metadata | game_settings: game_settings}}

    {:ok, updated_state}
  end

  def process_replay_event(
        <<0x10, _payload::binary>> = event,
        state
      ) do
    Logger.debug("Got message splitter. Size: #{byte_size(event)}")
    {:ok, state}
  end

  def process_replay_event(
        <<0x39, _payload::binary>>,
        state
      ) do
    ConnLogger.info("Game ended")
    {:ok, state}
  end

  def process_replay_event(
        <<_command::unsigned-integer-size(8), _payload::binary>>,
        state
      ) do
    {:ok, state}
  end
end

defmodule Slippi.Connection.PlayerParser do
  @moduledoc """
  Parses player data from Slippi replay game start payloads.
  """

  @doc """
  Parses player data from the game start payload for a specific player index.
  Returns nil if the player doesn't exist (port is 0).
  """
  @spec parse_player(binary(), integer()) :: map() | nil
  def parse_player(payload, player_index) when player_index in 0..3 do
    # Check if port is valid (not 0)
    port_offset = 0x61 + player_index * 0x24
    port = binary_part(payload, port_offset, 1) |> :binary.decode_unsigned()

    if port == 0 do
      nil
    else
      # Controller Fix parsing
      cf_offset = player_index * 0x8
      dashback = binary_part(payload, 0x141 + cf_offset, 4) |> :binary.decode_unsigned()
      shield_drop = binary_part(payload, 0x145 + cf_offset, 4) |> :binary.decode_unsigned()

      controller_fix =
        cond do
          dashback != shield_drop -> "Mixed"
          dashback == 1 -> "UCF"
          dashback == 2 -> "Dween"
          true -> "None"
        end

      # Nametag parsing
      nametag_length = 0x10
      nametag_offset = player_index * nametag_length
      nametag_start = 0x161 + nametag_offset
      nametag_data = binary_part(payload, nametag_start, nametag_length)
      # Convert Uint8Array to Buffer equivalent in Elixir
      nametag = decode_shift_jis(nametag_data)

      # Display name parsing
      display_name_length = 0x10
      display_name_offset = player_index * display_name_length
      display_name_start = 0x1A1 + display_name_offset
      display_name_data = binary_part(payload, display_name_start, display_name_length)
      display_name = decode_shift_jis(display_name_data)

      # Connect code parsing
      connect_code_length = 0x10
      connect_code_offset = player_index * connect_code_length
      connect_code_start = 0x1E1 + connect_code_offset
      connect_code_data = binary_part(payload, connect_code_start, connect_code_length)
      connect_code = decode_shift_jis(connect_code_data)

      # User ID parsing
      user_id_length = 0x1F
      user_id_offset = player_index * user_id_length
      user_id_start = 0x221 + user_id_offset
      user_id_data = binary_part(payload, user_id_start, user_id_length)
      user_id = decode_utf8(user_id_data)

      # Other player data
      character_id =
        binary_part(payload, 0x65 + player_index * 0x24, 1) |> :binary.decode_unsigned()

      player_type =
        binary_part(payload, 0x66 + player_index * 0x24, 1) |> :binary.decode_unsigned()

      starting_stocks =
        binary_part(payload, 0x67 + player_index * 0x24, 1) |> :binary.decode_unsigned()

      costume_index =
        binary_part(payload, 0x68 + player_index * 0x24, 1) |> :binary.decode_unsigned()

      team_shade =
        binary_part(payload, 0x6C + player_index * 0x24, 1) |> :binary.decode_unsigned()

      handicap = binary_part(payload, 0x6D + player_index * 0x24, 1) |> :binary.decode_unsigned()
      team_id = binary_part(payload, 0x6E + player_index * 0x24, 1) |> :binary.decode_unsigned()

      # Construct player object
      %{
        port: port,
        character_id: character_id,
        player_type: player_type,
        starting_stocks: starting_stocks,
        costume_index: costume_index,
        team_shade: team_shade,
        handicap: handicap,
        team_id: team_id,
        controller_fix: controller_fix,
        nametag: nametag,
        display_name: display_name,
        connect_code: connect_code,
        user_id: user_id
      }
    end
  end

  @doc """
  Decodes a binary string encoded with Shift-JIS, removing null terminators.
  Similar to the iconv.decode + splitting by null in the TypeScript code.
  """
  def decode_shift_jis(binary) do
    try do
      # Convert binary to a list of bytes for processing
      bytes = :binary.bin_to_list(binary)

      # Find the first null terminator or take the whole string
      null_pos = Enum.find_index(bytes, &(&1 == 0))
      relevant_bytes = if null_pos, do: Enum.take(bytes, null_pos), else: bytes

      # Convert back to binary for Codepagex processing
      data = :binary.list_to_bin(relevant_bytes)

      # Decode using Shift-JIS and convert to halfwidth if possible
      case Codepagex.from_string(data, :"VENDORS/MICSFT/WINDOWS/CP932") do
        {:ok, string} -> to_halfwidth(string)
        _ -> ""
      end
    rescue
      _ -> ""
    end
  end

  @doc """
  Decodes a binary string encoded with UTF-8, removing null terminators.
  """
  def decode_utf8(binary) do
    try do
      bytes = :binary.bin_to_list(binary)
      null_pos = Enum.find_index(bytes, &(&1 == 0))
      relevant_bytes = if null_pos, do: Enum.take(bytes, null_pos), else: bytes
      data = :binary.list_to_bin(relevant_bytes)

      case String.valid?(data) do
        true -> data
        false -> ""
      end
    rescue
      _ -> ""
    end
  end

  @doc """
  Converts fullwidth characters to halfwidth when possible.
  This is a simplified version of the toHalfwidth function in the TypeScript code.
  You may need to expand this based on your specific requirements.
  """
  def to_halfwidth(string) do
    # This is a simplified implementation
    # You might want to add more conversions based on your needs
    string
    |> String.replace("！", "!")
    |> String.replace("？", "?")
    |> String.replace("：", ":")
    |> String.replace("；", ";")
    |> String.replace("，", ",")
    |> String.replace("．", ".")
    |> String.replace("　", " ")
  end
end
