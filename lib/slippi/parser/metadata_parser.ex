defmodule Slippi.Parser.MetadataParser do
  @moduledoc """
  Utilities for parsing metadata from a Slippi replay.
  """
  import Bitwise
  require Logger

  @type player :: %{
          player_index: integer(),
          port: integer(),
          character_id: integer(),
          player_type: integer(),
          starting_stocks: integer(),
          costume_index: integer(),
          team_shade: integer(),
          handicap: integer(),
          team_id: integer(),
          controller_fix: String.t(),
          nametag: String.t(),
          display_name: String.t(),
          connect_code: String.t(),
          user_id: String.t()
        }

  @spec parse_game_start(binary()) :: {:ok, map()} | {:error, atom()}
  def parse_game_start(payload) do
    players =
      Enum.map([0, 1, 2, 3], fn player_index ->
        parse_player(payload, player_index)
      end)
      |> Enum.filter(&(Map.get(&1, :player_type) != 3))

    Logger.debug("Parsed players: #{inspect(players)}")

    # SLP Version
    slp_version =
      "#{read_uint_8(payload, 0x1)}.#{read_uint_8(payload, 0x2)}.#{read_uint_8(payload, 0x3)}"

    Logger.debug("SLP Version: #{slp_version}")

    # Game settings
    # For bit flags, we need to do bitwise operations
    timer_type = read_uint_8(payload, 0x5) &&& 0x03
    in_game_mode = read_uint_8(payload, 0x5) &&& 0xE0

    Logger.debug("Timer type: #{timer_type}")
    Logger.debug("In game mode: #{in_game_mode}")

    friendly_fire_enabled = read_uint_8(payload, 0x6) != 0

    Logger.debug("Friendly fire enabled: #{friendly_fire_enabled}")

    is_teams = read_uint_8(payload, 0xD) != 0
    item_spawn_behavior = read_uint_8(payload, 0x10)
    stage_id = read_uint_16(payload, 0x13)
    starting_timer_seconds = read_uint_32(payload, 0x15)

    Logger.debug("Is teams: #{is_teams}")
    Logger.debug("Item spawn behavior: #{item_spawn_behavior}")
    Logger.debug("Stage ID: #{stage_id}")
    Logger.debug("Starting timer seconds: #{starting_timer_seconds}")

    # Note: getEnabledItems would require more complex bit parsing
    # Simplified version for now
    enabled_items = %{}

    scene = read_uint_8(payload, 0x1A3)
    game_mode = read_uint_8(payload, 0x1A4)
    language = read_uint_8(payload, 0x2BD)

    Logger.debug("Scene: #{scene}")
    Logger.debug("Game mode: #{game_mode}")
    Logger.debug("Language: #{language}")

    # gameInfoBlock would need implementation similar to TypeScript version
    game_info_block = %{}

    random_seed = read_uint_32(payload, 0x13D)
    is_pal = read_uint_8(payload, 0x1A1) != 0
    is_frozen_ps = read_uint_8(payload, 0x1A2) != 0

    # Match info
    match_id_length = 51
    match_id_start = 0x2BE
    match_id_data = binary_part(payload, match_id_start, match_id_length)
    match_id = decode_utf8(match_id_data)

    game_number = read_uint_32(payload, 0x2F1)
    tiebreaker_number = read_uint_32(payload, 0x2F5)

    match_info = %{
      match_id: match_id,
      game_number: game_number,
      tiebreaker_number: tiebreaker_number
    }

    Logger.debug("Match info: #{inspect(match_info)}")

    game_settings = %{
      slp_version: slp_version,
      timer_type: timer_type,
      in_game_mode: in_game_mode,
      friendly_fire_enabled: friendly_fire_enabled,
      is_teams: is_teams,
      item_spawn_behavior: item_spawn_behavior,
      stage_id: stage_id,
      starting_timer_seconds: starting_timer_seconds,
      enabled_items: enabled_items,
      players: players,
      scene: scene,
      game_mode: game_mode,
      language: language,
      game_info_block: game_info_block,
      random_seed: random_seed,
      is_pal: is_pal,
      is_frozen_ps: is_frozen_ps,
      match_info: match_info
    }

    Logger.debug("Game settings: #{inspect(game_settings)}")

    {:ok, game_settings}
  end

  defp read_uint_16(payload, offset) do
    try do
      :binary.decode_unsigned(binary_part(payload, offset, 2))
    rescue
      _ ->
        Logger.error("Error reading uint16 at offset #{offset}")
        nil
    end
  end

  defp read_uint_8(payload, offset) do
    try do
      :binary.decode_unsigned(binary_part(payload, offset, 1))
    rescue
      _ ->
        Logger.error("Error reading uint8 at offset #{offset}")
        nil
    end
  end

  defp read_uint_32(payload, offset) do
    try do
      :binary.decode_unsigned(binary_part(payload, offset, 4))
    rescue
      _ ->
        Logger.error("Error reading uint32 at offset #{offset}")
        nil
    end
  end

  @doc """
  Parses player data from the game start payload for a specific player index.
  Returns nil if the player doesn't exist (port is 0).
  """
  @spec parse_player(binary(), integer()) :: player() | nil
  def parse_player(payload, player_index) when player_index in 0..3 do
    port = player_index + 1

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
      player_index: player_index,
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
      case Codepagex.to_string(data, "VENDORS/MICSFT/WINDOWS/CP932") do
        {:ok, string} -> to_halfwidth(string)
        _ -> "FAILED DECODING"
      end
    rescue
      _ -> "FAILED OTHERWISE"
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
