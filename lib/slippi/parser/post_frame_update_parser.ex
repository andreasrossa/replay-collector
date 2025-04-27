defmodule Slippi.Parser.PostFrameUpdateParser do
  import Slippi.Parser.ParsingUtilities

  @moduledoc """
  Parses the post frame update message.
  """

  @spec parse_post_frame_update(binary()) :: {:ok, map()} | {:error, any()}
  def parse_post_frame_update(payload) do
    try do
      self_induced_speeds = %{
        air_x: read_float(payload, 0x35),
        y: read_float(payload, 0x39),
        attack_x: read_float(payload, 0x3D),
        attack_y: read_float(payload, 0x41),
        ground_x: read_float(payload, 0x45)
      }

      post_frame_update = %{
        frame: read_int_32(payload, 0x1),
        player_index: read_uint_8(payload, 0x5),
        is_follower: read_bool(payload, 0x6),
        internal_character_id: read_uint_8(payload, 0x7),
        action_state_id: read_uint_16(payload, 0x8),
        position_x: read_float(payload, 0xA),
        position_y: read_float(payload, 0xE),
        facing_direction: read_float(payload, 0x12),
        percent: read_float(payload, 0x16),
        shield_size: read_float(payload, 0x1A),
        last_attack_landed: read_uint_8(payload, 0x1E),
        current_combo_count: read_uint_8(payload, 0x1F),
        last_hit_by: read_uint_8(payload, 0x20),
        stocks_remaining: read_uint_8(payload, 0x21),
        action_state_counter: read_float(payload, 0x22),
        misc_action_state: read_float(payload, 0x2B),
        is_airborne: read_bool(payload, 0x2F),
        last_ground_id: read_uint_16(payload, 0x30),
        jumps_remaining: read_uint_8(payload, 0x32),
        l_cancel_status: read_uint_8(payload, 0x33),
        hurtbox_collision_state: read_uint_8(payload, 0x34),
        self_induced_speeds: self_induced_speeds,
        hitlag_remaining: read_float(payload, 0x49),
        animation_index: read_uint_32(payload, 0x4D),
        instance_hit_by: read_uint_16(payload, 0x51),
        instance_id: read_uint_16(payload, 0x53)
      }

      {:ok, post_frame_update}
    rescue
      error ->
        {:error, error}
    end
  end
end
