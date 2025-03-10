defmodule Slippi.Parser.MessageParser do
  require Logger
  import Bitwise, only: [band: 2]

  # Command enum values from slippi-js
  defmodule Command do
    @moduledoc """
    Constants for Slippi command bytes
    """

    # Define all commands in a single map
    @commands %{
      split_message: 0x10,
      message_sizes: 0x35,
      game_start: 0x36,
      pre_frame_update: 0x37,
      post_frame_update: 0x38,
      game_end: 0x39,
      frame_start: 0x3A,
      item_update: 0x3B,
      frame_bookend: 0x3C,
      gecko_list: 0x3D
    }

    @type command_name ::
            :split_message
            | :message_sizes
            | :game_start
            | :pre_frame_update
            | :post_frame_update
            | :game_end
            | :frame_start
            | :item_update
            | :frame_bookend
            | :gecko_list

    @spec commands() :: %{command_name() => byte()}
    def commands, do: @commands

    @spec get(command_name()) :: byte() | nil
    def get(command_name), do: @commands[command_name]
  end

  # Parse message based on command byte using function overloads

  @spec parse_message(binary()) :: map() | nil

  # Game Start (0x36)
  def parse_message(<<0x36, _payload::binary>> = data) do
    # Helper function to get player data
    get_player_object = fn player_index ->
      # Controller Fix stuff
      cf_offset = player_index * 0x8
      dashback = read_uint_32(data, 0x141 + cf_offset)
      shield_drop = read_uint_32(data, 0x145 + cf_offset)

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
      nametag_data = safe_binary_part(data, nametag_start, nametag_length)

      nametag =
        case nametag_data do
          {:ok, binary} -> decode_shift_jis(binary)
          _ -> nil
        end

      # Display name parsing
      display_name_length = 0x1F
      display_name_offset = player_index * display_name_length
      display_name_start = 0x1A5 + display_name_offset
      display_name_data = safe_binary_part(data, display_name_start, display_name_length)

      display_name =
        case display_name_data do
          {:ok, binary} -> decode_shift_jis(binary)
          _ -> nil
        end

      # Connect code parsing
      connect_code_length = 0xA
      connect_code_offset = player_index * connect_code_length
      connect_code_start = 0x221 + connect_code_offset
      connect_code_data = safe_binary_part(data, connect_code_start, connect_code_length)

      connect_code =
        case connect_code_data do
          {:ok, binary} -> decode_shift_jis(binary)
          _ -> nil
        end

      # User ID parsing
      user_id_length = 0x1F
      user_id_offset = player_index * user_id_length
      user_id_start = 0x24D + user_id_offset
      user_id_data = safe_binary_part(data, user_id_start, user_id_length)

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
        character_id: read_uint_8(data, 0x65 + offset),
        type: read_uint_8(data, 0x66 + offset),
        start_stocks: read_uint_8(data, 0x67 + offset),
        character_color: read_uint_8(data, 0x68 + offset),
        team_shade: read_uint_8(data, 0x6F + offset),
        handicap: read_uint_8(data, 0x6D + offset),
        team_id: read_uint_8(data, 0x6E + offset),
        stamina_mode: read_bool(data, 0x69 + offset),
        silent_character: read_bool(data, 0x6A + offset),
        invisible: read_bool(data, 0x6C + offset),
        low_gravity: read_bool(data, 0x6B + offset),
        black_stock_icon: read_bool(data, 0x70 + offset),
        metal: read_bool(data, 0x71 + offset),
        start_on_angel_platform: read_bool(data, 0x72 + offset),
        rumble_enabled: read_bool(data, 0x73 + offset),
        cpu_level: read_uint_8(data, 0x74 + offset),
        offense_ratio: read_float(data, 0x75 + offset),
        defense_ratio: read_float(data, 0x79 + offset),
        model_scale: read_float(data, 0x85 + offset),
        controller_fix: controller_fix,
        nametag: nametag,
        display_name: display_name,
        connect_code: connect_code,
        user_id: user_id
      }
    end

    # Get game info block
    game_info_block = %{
      game_bitfield1: read_uint_8(data, 0x5),
      game_bitfield2: read_uint_8(data, 0x6),
      game_bitfield3: read_uint_8(data, 0x7),
      game_bitfield4: read_uint_8(data, 0x8),
      bomb_rain_enabled: read_uint_8(data, 0xB) > 0,
      self_destruct_score_value: read_int_8(data, 0x11),
      item_spawn_bitfield1: read_uint_8(data, 0x28),
      item_spawn_bitfield2: read_uint_8(data, 0x29),
      item_spawn_bitfield3: read_uint_8(data, 0x2A),
      item_spawn_bitfield4: read_uint_8(data, 0x2B),
      item_spawn_bitfield5: read_uint_8(data, 0x2C),
      damage_ratio: read_float(data, 0x35)
    }

    # Get enabled items
    enabled_items = get_enabled_items(data)

    # Match ID parsing
    match_id_length = 51
    match_id_start = 0x2BE
    match_id_data = safe_binary_part(data, match_id_start, match_id_length)

    match_id =
      case match_id_data do
        {:ok, binary} -> decode_utf8(binary)
        _ -> nil
      end

    # Create the game settings map
    %{
      slp_version:
        "#{read_uint_8(data, 0x1)}.#{read_uint_8(data, 0x2)}.#{read_uint_8(data, 0x3)}",
      timer_type: band(read_uint_8(data, 0x5), 0x03),
      in_game_mode: band(read_uint_8(data, 0x5), 0xE0),
      friendly_fire_enabled: read_bool(data, 0x6),
      is_teams: read_bool(data, 0xD),
      item_spawn_behavior: read_uint_8(data, 0x10),
      stage_id: read_uint_16(data, 0x13),
      starting_timer_seconds: read_uint_32(data, 0x15),
      enabled_items: enabled_items,
      players: Enum.map(0..3, get_player_object),
      scene: read_uint_8(data, 0x1A3),
      game_mode: read_uint_8(data, 0x1A4),
      language: read_uint_8(data, 0x2BD),
      game_info_block: game_info_block,
      random_seed: read_uint_32(data, 0x13D),
      is_pal: read_bool(data, 0x1A1),
      is_frozen_ps: read_bool(data, 0x1A2),
      match_info: %{
        match_id: match_id,
        game_number: read_uint_32(data, 0x2F1),
        tiebreaker_number: read_uint_32(data, 0x2F5)
      }
    }
  end

  # Frame Start (0x3A)
  def parse_message(<<0x3A, _payload::binary>> = data) do
    frame = read_int_32(data, 0x1)
    seed = read_uint_32(data, 0x5)
    scene_frame_counter = read_uint_32(data, 0x9)

    %{
      frame: frame,
      seed: seed,
      scene_frame_counter: scene_frame_counter
    }
  end

  # Post Frame Update (0x38)
  def parse_message(<<0x38, _payload::binary>> = data) do
    self_induced_speeds = %{
      air_x: read_float(data, 0x35),
      y: read_float(data, 0x39),
      attack_x: read_float(data, 0x3D),
      attack_y: read_float(data, 0x41),
      ground_x: read_float(data, 0x45)
    }

    %{
      frame: read_int_32(data, 0x1),
      player_index: read_uint_8(data, 0x5),
      is_follower: read_bool(data, 0x6),
      internal_character_id: read_uint_8(data, 0x7),
      action_state_id: read_uint_16(data, 0x8),
      position_x: read_float(data, 0xA),
      position_y: read_float(data, 0xE),
      facing_direction: read_float(data, 0x12),
      percent: read_float(data, 0x16),
      shield_size: read_float(data, 0x1A),
      last_attack_landed: read_uint_8(data, 0x1E),
      current_combo_count: read_uint_8(data, 0x1F),
      last_hit_by: read_uint_8(data, 0x20),
      stocks_remaining: read_uint_8(data, 0x21),
      action_state_counter: read_float(data, 0x22),
      misc_action_state: read_float(data, 0x2B),
      is_airborne: read_bool(data, 0x2F),
      last_ground_id: read_uint_16(data, 0x30),
      jumps_remaining: read_uint_8(data, 0x32),
      l_cancel_status: read_uint_8(data, 0x33),
      hurtbox_collision_state: read_uint_8(data, 0x34),
      self_induced_speeds: self_induced_speeds,
      hitlag_remaining: read_float(data, 0x49),
      animation_index: read_uint_32(data, 0x4D),
      instance_hit_by: read_uint_16(data, 0x51),
      instance_id: read_uint_16(data, 0x53)
    }
  end

  # Pre Frame Update (0x37)
  def parse_message(<<0x37, _payload::binary>> = data) do
    %{
      frame: read_int_32(data, 0x1),
      player_index: read_uint_8(data, 0x5),
      is_follower: read_bool(data, 0x6),
      seed: read_uint_32(data, 0x7),
      action_state_id: read_uint_16(data, 0xB),
      position_x: read_float(data, 0xD),
      position_y: read_float(data, 0x11),
      facing_direction: read_float(data, 0x15),
      joystick_x: read_float(data, 0x19),
      joystick_y: read_float(data, 0x1D),
      c_stick_x: read_float(data, 0x21),
      c_stick_y: read_float(data, 0x25),
      trigger: read_float(data, 0x29),
      buttons: read_uint_32(data, 0x2D),
      physical_buttons: read_uint_16(data, 0x31),
      physical_l_trigger: read_float(data, 0x33),
      physical_r_trigger: read_float(data, 0x37),
      raw_joystick_x: read_int_8(data, 0x3B),
      percent: read_float(data, 0x3C)
    }
  end

  # Item Update (0x3B)
  def parse_message(<<0x3B, _payload::binary>> = data) do
    %{
      frame: read_int_32(data, 0x1),
      type_id: read_uint_16(data, 0x5),
      state: read_uint_8(data, 0x7),
      facing_direction: read_float(data, 0x8),
      velocity_x: read_float(data, 0xC),
      velocity_y: read_float(data, 0x10),
      position_x: read_float(data, 0x14),
      position_y: read_float(data, 0x18),
      damage_taken: read_uint_16(data, 0x1C),
      expiration_timer: read_float(data, 0x1E),
      spawn_id: read_uint_32(data, 0x22),
      missile_type: read_uint_8(data, 0x26),
      turnip_face: read_uint_8(data, 0x27),
      charge_shot_launched: read_uint_8(data, 0x28),
      charge_power: read_uint_8(data, 0x29),
      owner: read_int_8(data, 0x2A),
      instance_id: read_uint_16(data, 0x2B)
    }
  end

  # Frame Bookend (0x3C)
  def parse_message(<<0x3C, _payload::binary>> = data) do
    %{
      frame: read_int_32(data, 0x1),
      latest_finalized_frame: read_int_32(data, 0x5)
    }
  end

  # Game End (0x39)
  def parse_message(<<0x39, _payload::binary>> = data) do
    placements =
      for player_index <- 0..3 do
        position = read_int_8(data, 0x3 + player_index)
        %{player_index: player_index, position: position}
      end

    %{
      game_end_method: read_uint_8(data, 0x1),
      lras_initiator_index: read_int_8(data, 0x2),
      placements: placements
    }
  end

  # Fallback for unhandled commands
  def parse_message(<<command, _payload::binary>>) do
    Logger.warning("Unhandled command: #{command}")
    nil
  end

  # Helper function to get enabled items
  defp get_enabled_items(data) do
    offsets = [0x1, 0x100, 0x10000, 0x1000000, 0x100000000]

    Enum.reduce(Enum.with_index(offsets), 0, fn {byte_offset, index}, acc ->
      byte = read_uint_8(data, 0x28 + index) || 0
      acc + byte * byte_offset
    end)
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

      # Convert back to binary for processing
      data = :binary.list_to_bin(relevant_bytes)

      # Decode using Shift-JIS if Codepagex is available
      # Otherwise return the data as is (you may want to add proper handling)
      case Code.ensure_loaded?(Codepagex) do
        true ->
          case Codepagex.to_string(data, "VENDORS/MICSFT/WINDOWS/CP932") do
            {:ok, string} -> to_halfwidth(string)
            _ -> nil
          end

        false ->
          # Fallback if Codepagex is not available
          data
      end
    rescue
      _ -> nil
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
        false -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc """
  Converts fullwidth characters to halfwidth when possible.
  This is a simplified version of the toHalfwidth function in the TypeScript code.
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

  # Utility functions for reading different data types
  @spec read_int_32(binary(), non_neg_integer()) :: integer() | nil
  defp read_int_32(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 4),
         <<value::signed-integer-32>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading int32 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding int32 at offset #{offset}")
        nil
    end
  end

  @spec read_uint_16(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp read_uint_16(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 2),
         <<value::unsigned-integer-16>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading uint16 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding uint16 at offset #{offset}")
        nil
    end
  end

  @spec read_uint_8(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer() | nil
  defp read_uint_8(payload, offset, bitmask \\ 0xFF) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 1),
         <<value::unsigned-integer-8>> <- binary_data do
      band(value, bitmask)
    else
      {:error, reason} ->
        Logger.error("Error reading uint8 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding uint8 at offset #{offset}")
        nil
    end
  end

  @spec read_uint_32(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp read_uint_32(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 4),
         <<value::unsigned-integer-32>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading uint32 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding uint32 at offset #{offset}")
        nil
    end
  end

  @spec read_int_8(binary(), non_neg_integer()) :: integer() | nil
  defp read_int_8(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 1),
         <<value::signed-integer-8>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading int8 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding int8 at offset #{offset}")
        nil
    end
  end

  @spec read_float(binary(), non_neg_integer()) :: float() | nil
  defp read_float(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 4),
         <<value::float-32>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading float at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding float at offset #{offset}")
        nil
    end
  end

  @spec read_bool(binary(), non_neg_integer()) :: boolean() | nil
  defp read_bool(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 1),
         <<value::unsigned-integer-8>> <- binary_data do
      value != 0
    else
      {:error, reason} ->
        Logger.error("Error reading bool at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding bool at offset #{offset}")
        nil
    end
  end

  # Helper function to safely extract a binary part
  @spec safe_binary_part(binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, String.t()}
  defp safe_binary_part(binary, start, length) do
    try do
      {:ok, binary_part(binary, start, length)}
    rescue
      ArgumentError -> {:error, "Invalid offset or length"}
    end
  end
end
