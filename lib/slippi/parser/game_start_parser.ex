defmodule Slippi.Parser.GameStartParser do
  import Slippi.Parser.ParsingUtilities
  import Bitwise, only: [band: 2]
  require Collector.Utils.ConsoleLogger, as: Logger

  @moduledoc """
  Parses the game start message.
  """

  @spec parse_game_start(binary()) :: {:ok, map()} | {:error, any()}
  def parse_game_start(payload) do
    try do
      # Get game info block
      game_info_block = %{
        game_bitfield1: read_uint_8(payload, 0x5),
        game_bitfield2: read_uint_8(payload, 0x6),
        game_bitfield3: read_uint_8(payload, 0x7),
        game_bitfield4: read_uint_8(payload, 0x8),
        bomb_rain_enabled: read_uint_8(payload, 0xB) > 0,
        self_destruct_score_value: read_int_8(payload, 0x11),
        item_spawn_bitfield1: read_uint_8(payload, 0x28),
        item_spawn_bitfield2: read_uint_8(payload, 0x29),
        item_spawn_bitfield3: read_uint_8(payload, 0x2A),
        item_spawn_bitfield4: read_uint_8(payload, 0x2B),
        item_spawn_bitfield5: read_uint_8(payload, 0x2C),
        damage_ratio: read_float(payload, 0x35)
      }

      # Get enabled items
      enabled_items = get_enabled_items(payload)

      # Match ID parsing
      match_id_length = 51
      match_id_start = 0x2BE
      match_id_data = safe_binary_part(payload, match_id_start, match_id_length)

      match_id =
        case match_id_data do
          {:ok, binary} -> decode_utf8(binary)
          _ -> nil
        end

      # Create the game settings map
      game_settings = %{
        slp_version:
          "#{read_uint_8(payload, 0x1)}.#{read_uint_8(payload, 0x2)}.#{read_uint_8(payload, 0x3)}",
        timer_type: band(read_uint_8(payload, 0x5), 0x03),
        in_game_mode: band(read_uint_8(payload, 0x5), 0xE0),
        friendly_fire_enabled: read_bool(payload, 0x6),
        is_teams: read_bool(payload, 0xD),
        item_spawn_behavior: read_uint_8(payload, 0x10),
        stage_id: read_uint_16(payload, 0x13),
        starting_timer_seconds: read_uint_32(payload, 0x15),
        enabled_items: enabled_items,
        players: Enum.map(0..3, &get_player_object(&1, payload)),
        scene: read_uint_8(payload, 0x1A3),
        game_mode: read_uint_8(payload, 0x1A4),
        language: read_uint_8(payload, 0x2BD),
        game_info_block: game_info_block,
        random_seed: read_uint_32(payload, 0x13D),
        is_pal: read_bool(payload, 0x1A1),
        is_frozen_ps: read_bool(payload, 0x1A2),
        match_info: %{
          match_id: match_id,
          game_number: read_uint_32(payload, 0x2F1),
          tiebreaker_number: read_uint_32(payload, 0x2F5)
        }
      }

      {:ok, game_settings}
    rescue
      error ->
        Logger.debug("Error parsing game start: #{inspect(error)}")
        {:error, error}
    end
  end

  defp get_player_object(player_index, payload) do
    # Controller Fix stuff
    cf_offset = player_index * 0x8
    dashback = read_uint_32(payload, 0x141 + cf_offset)
    shield_drop = read_uint_32(payload, 0x145 + cf_offset)

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
    nametag_data = safe_binary_part(payload, nametag_start, nametag_length)

    nametag =
      case nametag_data do
        {:ok, binary} -> decode_shift_jis(binary)
        _ -> nil
      end

    # Display name parsing
    display_name_length = 0x1F
    display_name_offset = player_index * display_name_length
    display_name_start = 0x1A5 + display_name_offset
    display_name_data = safe_binary_part(payload, display_name_start, display_name_length)

    display_name =
      case display_name_data do
        {:ok, binary} -> decode_shift_jis(binary)
        _ -> nil
      end

    # Connect code parsing
    connect_code_length = 0xA
    connect_code_offset = player_index * connect_code_length
    connect_code_start = 0x221 + connect_code_offset
    connect_code_data = safe_binary_part(payload, connect_code_start, connect_code_length)

    connect_code =
      case connect_code_data do
        {:ok, binary} -> decode_shift_jis(binary)
      end

    # User ID parsing
    user_id_length = 0x1F
    user_id_offset = player_index * user_id_length
    user_id_start = 0x24D + user_id_offset
    user_id_data = safe_binary_part(payload, user_id_start, user_id_length)

    user_id =
      case user_id_data do
        {:ok, binary} -> decode_utf8(binary)
        _ -> nil
      end

    # Player data from various offsets
    offset = player_index * 0x24

    # Create the player map
    %{
      player_index: player_index,
      port: player_index + 1,
      character_id: read_uint_8(payload, 0x65 + offset),
      type: read_uint_8(payload, 0x66 + offset),
      start_stocks: read_uint_8(payload, 0x67 + offset),
      character_color: read_uint_8(payload, 0x68 + offset),
      team_shade: read_uint_8(payload, 0x6F + offset),
      handicap: read_uint_8(payload, 0x6D + offset),
      team_id: read_uint_8(payload, 0x6E + offset),
      stamina_mode: read_bool(payload, 0x69 + offset),
      silent_character: read_bool(payload, 0x6A + offset),
      invisible: read_bool(payload, 0x6C + offset),
      low_gravity: read_bool(payload, 0x6B + offset),
      black_stock_icon: read_bool(payload, 0x70 + offset),
      metal: read_bool(payload, 0x71 + offset),
      start_on_angel_platform: read_bool(payload, 0x72 + offset),
      rumble_enabled: read_bool(payload, 0x73 + offset),
      cpu_level: read_uint_8(payload, 0x74 + offset),
      offense_ratio: read_float(payload, 0x75 + offset),
      defense_ratio: read_float(payload, 0x79 + offset),
      model_scale: read_float(payload, 0x85 + offset),
      controller_fix: controller_fix,
      nametag: nametag,
      display_name: display_name,
      connect_code: connect_code,
      user_id: user_id
    }
  end

  # Helper function to get enabled items
  defp get_enabled_items(data) do
    offsets = [0x1, 0x100, 0x10000, 0x1000000, 0x100000000]

    Enum.reduce(Enum.with_index(offsets), 0, fn {byte_offset, index}, acc ->
      byte = read_uint_8(data, 0x28 + index) || 0
      acc + byte * byte_offset
    end)
  end
end
