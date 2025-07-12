defmodule Collector.Workers.ReplaySession do
  @moduledoc """
  Handles a single replay session by processing Slippi events and maintaining
  game state throughout the session lifecycle.

  • Tracks game start, post-frame updates, and game end events
  • Maintains player states including character usage, stocks, and percentages
  • Automatically terminates when a game ends
  • Collects all event chunks for replay reconstruction
  """

  use GenServer
  alias Slippi.Parser.GameEndParser
  alias Slippi.Parser.GameStartParser
  alias Slippi.Parser.PostFrameUpdateParser

  require Collector.Utils.ConsoleLogger, as: ConnLogger

  # -----------------------------------------------------------------------------
  # State
  # -----------------------------------------------------------------------------

  defmodule State do
    @enforce_keys [:session_id, :started_at, :state, :chunks]
    defstruct [
      :session_id,
      :started_at,
      :game_info,
      :game_end_info,
      :state,
      :chunks
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            started_at: DateTime.t(),
            game_info: game_info() | nil,
            game_end_info: game_end_info() | nil,
            state: :game_not_started | :game_started | :game_ended | :game_error,
            chunks: [binary()]
          }

    @type game_info :: %{
            players: %{non_neg_integer() => player_data()},
            stage_id: non_neg_integer(),
            last_frame: non_neg_integer()
          }

    @type game_end_info :: %{
            game_end_type: non_neg_integer(),
            lras: non_neg_integer()
          }

    @type player_data :: %{
            character_id: non_neg_integer(),
            tag: String.t(),
            skin: non_neg_integer(),
            percent: float(),
            stocks: non_neg_integer(),
            character_usage: int_map()
          }

    @type int_map :: %{integer() => integer()}
  end

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @spec process_event(pid(), binary()) :: :ok | {:error, any()}
  def process_event(pid, event) do
    GenServer.cast(pid, {:process_event, event})
  end

  # -----------------------------------------------------------------------------
  # Server Callbacks
  # -----------------------------------------------------------------------------

  @impl true
  def init(session_id) do
    state = %State{
      session_id: session_id,
      started_at: DateTime.utc_now(),
      state: :game_not_started,
      chunks: []
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:process_event, event}, %State{} = state) do
    case process_event_with_state_update(event, state) do
      {:ok, %State{state: :game_ended} = updated_state} ->
        {:stop, :normal, updated_state}

      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, reason, updated_state} ->
        {:stop, reason, updated_state}
    end
  end

  # -----------------------------------------------------------------------------
  # Event Handlers
  # -----------------------------------------------------------------------------

  # 0x36 - Game Start
  # 0x38 - Post Frame Update
  # 0x39 - Game End

  # ------------------- Game Start ----------------------------------------------

  defp handle_replay_event(<<0x36, _payload::binary>> = event, %State{} = state) do
    case GameStartParser.parse_game_start(event) do
      {:ok, %{players: players, stage_id: stage_id}} ->
        player_state =
          players
          |> Enum.filter(fn player -> player.type != 3 end)
          |> Enum.map(fn player ->
            {player.player_index,
             %{
               character_id: player.character_id,
               character_usage: %{},
               tag: player.nametag,
               skin: player.skin,
               percent: 0,
               stocks: player.start_stocks
             }}
          end)
          |> Map.new()

        game_info = %{
          stage_id: stage_id,
          players: player_state,
          last_frame: nil
        }

        {:ok, %State{state | game_info: game_info, state: :game_started}}

      {:error, reason} ->
        ConnLogger.error("Error parsing game start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ------------------- Post Frame Update ----------------------------------------

  defp handle_replay_event(<<0x38, _payload::binary>> = event, %State{} = state) do
    if state.state != :game_started do
      {:error, :game_not_started}
    else
      case PostFrameUpdateParser.parse_post_frame_update(event) do
        {:ok,
         %{
           frame: _frame,
           player_index: player_index,
           is_follower: is_follower,
           percent: percent,
           stocks_remaining: stocks_remaining,
           internal_character_id: internal_character_id
         }} ->
          if is_follower do
            {:ok, state}
          else
            player = state.game_info.players[player_index]

            updated_player = update_character_usage(player, internal_character_id)
            updated_player = Map.put(updated_player, :percent, percent)
            updated_player = Map.put(updated_player, :stocks, stocks_remaining)

            updated_players = Map.put(state.game_info.players, player_index, updated_player)

            updated_state =
              Map.put(state, :game_info, %{
                state.game_info
                | players: updated_players
              })

            {:ok, updated_state}
          end

        {:error, reason} ->
          ConnLogger.error("Error parsing post frame update: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # ------------------- Game End --------------------------------------------------

  defp handle_replay_event(<<0x39, payload::binary>>, %State{} = state) do
    if state.state != :game_started do
      {:error, :game_not_started}
    else
      case GameEndParser.parse_game_end(payload) do
        {:ok, %{game_end_type: game_end_type, lras: lras}} ->
          updated_state =
            Map.put(state, :game_end_info, %{
              game_end_type: game_end_type,
              lras: lras
            })

          {:ok, %State{updated_state | state: :game_ended}}

        {:error, reason} ->
          ConnLogger.error("Error parsing game end: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # ------------------- Other Events ---------------------------------------------

  defp handle_replay_event(_event, %State{} = state) do
    {:ok, state}
  end

  # -----------------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------------

  defp process_event_with_state_update(event, %State{} = state) do
    case handle_replay_event(event, state) do
      {:ok, updated_state} ->
        {:ok, save_event_to_state(event, updated_state)}

      {:error, reason} ->
        {:error, reason, save_event_to_state(event, state)}
    end
  end

  defp save_event_to_state(event, %State{} = state) do
    Map.put(state, :chunks, [event | state.chunks])
  end

  @spec update_character_usage(State.player_data(), non_neg_integer()) ::
          State.player_data()
  def update_character_usage(player, internal_character_id) do
    player
    |> Map.update(:character_usage, %{internal_character_id => 1}, fn usage ->
      Map.update(usage, internal_character_id, 1, &(&1 + 1))
    end)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Collector.SessionRegistry, {:session, session_id}}}
  end
end
