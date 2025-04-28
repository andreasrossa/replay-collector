defmodule Collector.Workers.ReplayProcessor.EventHandler do
  alias Slippi.Parser.PayloadSizesParser
  alias Slippi.Parser.GameStartParser
  alias Slippi.Parser.PostFrameUpdateParser
  alias Slippi.Parser.GameEndParser
  alias Collector.Utils.ConsoleLogger, as: ConnLogger

  @type payload_sizes :: %{byte() => non_neg_integer()}

  @moduledoc """
  Handles events from the Slippi connection.
  """

  @doc """
  Handle a payload sizes event and extract the payload sizes.
  Updates the state with the payload sizes.
  """
  @spec handle_payload_sizes(binary(), map()) :: {:ok, map()} | {:error, atom()}
  def handle_payload_sizes(
        <<0x35, _payload_length::unsigned-integer-size(8), payload::binary>>,
        state
      ) do
    case PayloadSizesParser.parse_payload_sizes(payload) do
      {:ok, payload_sizes} ->
        {:ok, Map.put(state, :payload_sizes, payload_sizes)}

      {:error, :remaining_bytes_less_than_zero} ->
        {:error, :invalid_payload_sizes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Handle a game start event.

  Extracts player and stage information from the payload and updates the state.
  """
  def handle_game_start(payload, state) do
    case GameStartParser.parse_game_start(payload) do
      {:ok, %{players: players, stage_id: stage_id}} ->
        player_state =
          players
          |> Enum.filter(fn player -> player.type != 3 end)
          |> Enum.map(fn player ->
            {player.player_index,
             %{
               character_usage: %{},
               names: %{
                 netplay: player.display_name,
                 code: player.connect_code
               }
             }}
          end)
          |> Map.new()

        character_ids =
          players
          |> Enum.filter(fn player -> player.type != 3 end)
          |> Enum.map(fn player -> player.character_id end)

        game_info = %{
          state.game_info
          | start_time: System.system_time(:millisecond),
            stage_id: stage_id,
            characters: character_ids,
            players: player_state
        }

        ConnLogger.info("New game started on stage #{stage_id} with players: #{inspect(players)}")

        # TODO: Post game start to API
        # API handler should post back to this genserver with game_id once request succeeds

        updated_state = Map.put(state, :game_info, game_info)
        updated_state = Map.put(updated_state, :status, :ongoing)

        {:ok, updated_state}

      {:error, reason} ->
        ConnLogger.debug("Error parsing game start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Handle a post frame update event.

  Extracts character usage and frame information from the payload and updates the state.
  """
  @spec handle_post_frame_update(binary(), map()) :: {:ok, map()} | {:error, any()}
  def handle_post_frame_update(
        payload,
        state
      ) do
    try do
      case PostFrameUpdateParser.parse_post_frame_update(payload) do
        {:ok,
         %{
           frame: frame,
           player_index: player_index,
           is_follower: is_follower,
           internal_character_id: internal_character_id
         }} ->
          if is_follower do
            {:ok, state}
          else
            player = state.game_info.players[player_index]

            updated_player =
              player
              |> Map.update(:character_usage, %{internal_character_id => 1}, fn usage ->
                Map.update(usage, internal_character_id, 1, &(&1 + 1))
              end)

            updated_players = Map.put(state.game_info.players, player_index, updated_player)

            updated_state =
              Map.put(state, :game_info, %{
                state.game_info
                | players: updated_players,
                  last_frame: frame
              })

            {:ok, updated_state}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      reason ->
        {:error, reason}
    end
  end

  @doc """
  Handle a game ended event.
  """
  def handle_game_ended(payload, state) do
    case GameEndParser.parse_game_end(payload) do
      {:ok, %{game_end_type: game_end_type, lras: lras}} ->
        ConnLogger.info(
          "Game ended with game end type #{inspect(game_end_type)} and lras #{inspect(lras)}"
        )

        updated_state = Map.put(state, :status, :done)

        updated_state =
          Map.put(updated_state, :game_info, %{
            state.game_info
            | game_end_type: game_end_type,
              lras: lras
          })

        Collector.Workers.FileHandler.finalize(state.file_manager, %{
          start_time: state.game_info.start_time,
          last_frame: state.game_info.last_frame,
          players: state.game_info.players,
          console_nickname: state.wii_console.nickname
        })

        {:ok, updated_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Handle any event that doesn't have a specific handler.
  """
  def handle_generic_event(_payload, state) do
    {:ok, state}
  end
end
