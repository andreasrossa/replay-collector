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
  alias Collector.Workers.FileHandler
  alias Slippi.Parser.GameEndParser
  alias Slippi.Parser.GameStartParser
  alias Slippi.Parser.PostFrameUpdateParser
  alias Slippi.WiiConsole

  require Collector.Utils.ConsoleLogger, as: ConnLogger

  # -----------------------------------------------------------------------------
  # State
  # -----------------------------------------------------------------------------

  defmodule State do
    @enforce_keys [:session_id, :started_at, :status, :chunks, :wii, :cursor, :uid]
    defstruct [
      :session_id,
      :token,
      :started_at,
      :game_info,
      :game_end_info,
      :status,
      :chunks,
      :wii,
      :cursor,
      :next_cursor,
      :uid
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            token: binary(),
            started_at: DateTime.t(),
            game_info: game_info() | nil,
            game_end_info: game_end_info() | nil,
            status: :not_started | :started | :ended | :error,
            chunks: [binary()],
            wii: WiiConsole.t(),
            cursor: binary(),
            next_cursor: binary() | nil,
            uid: String.t() | nil
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

  @spec start_link(String.t(), WiiConsole.t()) :: GenServer.on_start()
  def start_link(session_id, wii, token) do
    GenServer.start_link(__MODULE__, %{session_id: session_id, wii: wii, token: token},
      name: via_tuple(session_id)
    )
  end

  @spec process_event(pid(), binary(), binary(), binary()) :: :ok | {:error, :game_not_started}
  def process_event(pid, event, cursor, next_cursor) do
    GenServer.cast(pid, {:process_event, event, cursor, next_cursor})
  end

  @spec get_cursor(pid()) :: binary()
  def get_cursor(pid) do
    GenServer.call(pid, :get_cursor)
  end

  @spec get_uid(pid()) :: String.t() | nil
  def get_uid(pid) do
    GenServer.call(pid, :get_uid)
  end

  @spec get_status(pid()) :: :not_started | :started | :ended | :error
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  # -----------------------------------------------------------------------------
  # Server Callbacks
  # -----------------------------------------------------------------------------

  @impl true
  def init(%{session_id: session_id, wii: wii, token: token}) do
    now = DateTime.utc_now()

    state = %State{
      session_id: session_id,
      started_at: now,
      status: :not_started,
      chunks: [],
      wii: wii,
      cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
      next_cursor: nil,
      uid: nil,
      token: token
    }

    Registry.update_value(Collector.SessionRegistry, via_tuple(session_id), fn
      _ ->
        %{mac: wii.mac, status: :not_started, token: token}
    end)

    {:ok, state}
  end

  @impl true
  def handle_cast({:process_event, event, cursor, next_cursor}, %State{} = state) do
    state = save_event_to_state(event, state, cursor)

    state = %State{state | cursor: cursor, next_cursor: next_cursor}

    case handle_replay_event(event, state) do
      {:ok, %State{status: :ended} = updated_state} ->
        handle_game_end(updated_state)
        {:stop, :normal, updated_state}

      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call(:get_cursor, _from, %State{cursor: cursor} = state) do
    {:reply, cursor, state}
  end

  @impl true
  def handle_call(:get_uid, _from, %State{uid: uid} = state) do
    {:reply, uid, state}
  end

  @impl true
  def handle_call(:get_status, _from, %State{status: status} = state) do
    {:reply, status, state}
  end

  # -----------------------------------------------------------------------------
  # Event Handlers
  # -----------------------------------------------------------------------------

  # 0x36 - Game Start
  # 0x38 - Post Frame Update
  # 0x39 - Game End

  # ------------------- Game Start ----------------------------------------------

  @spec handle_replay_event(binary(), State.t()) :: {:ok, State.t()} | {:error, any()}
  defp handle_replay_event(<<0x36, _payload::binary>> = event, %State{} = state) do
    case GameStartParser.parse_game_start(event) do
      {:ok, %{players: players, stage_id: stage_id, match_info: match_info}} ->
        player_state =
          players
          # 0 = human, 1 = CPU, 2 = demo, 3 = empty
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

        Registry.update_value(
          Collector.SessionRegistry,
          via_tuple(state.session_id),
          &Map.put(&1, :status, :started)
        )

        {:ok, %State{state | game_info: game_info, status: :started, uid: match_info.match_id}}

      {:error, reason} ->
        ConnLogger.error("Error parsing game start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ------------------- Post Frame Update ----------------------------------------

  @spec handle_replay_event(binary(), State.t()) :: {:ok, State.t()} | {:error, any()}
  defp handle_replay_event(<<0x38, _payload::binary>> = event, %State{} = state) do
    if state.status != :started do
      {:error, :game_not_started}
    else
      case PostFrameUpdateParser.parse_post_frame_update(event) do
        {:ok,
         %{
           frame: frame,
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
                | players: updated_players,
                  last_frame: frame
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

  @spec handle_replay_event(binary(), State.t()) :: {:ok, State.t()} | {:error, any()}
  defp handle_replay_event(<<0x39, payload::binary>>, %State{} = state) do
    if state.status != :started do
      {:error, :game_not_started}
    else
      case GameEndParser.parse_game_end(payload) do
        {:ok, %{game_end_type: game_end_type, lras: lras}} ->
          updated_state =
            Map.put(state, :game_end_info, %{
              game_end_type: game_end_type,
              lras: lras
            })

          Registry.update_value(
            Collector.SessionRegistry,
            via_tuple(state.session_id),
            &Map.put(&1, :status, :ended)
          )

          {:ok, %State{updated_state | status: :ended}}

        {:error, reason} ->
          ConnLogger.error("Error parsing game end: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # ------------------- Other Events ---------------------------------------------

  @spec handle_replay_event(binary(), State.t()) :: {:ok, State.t()} | {:error, any()}
  defp handle_replay_event(_event, %State{} = state) do
    {:ok, state}
  end

  # -----------------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------------

  @spec handle_game_end(State.t()) :: :ok | {:error, any()}
  defp handle_game_end(%State{wii: wii, started_at: started_at, chunks: chunks} = state) do
    {:ok, file_handler} = FileHandler.start_link(started_at, wii.nickname)

    replay_binary = Enum.reverse(chunks) |> :binary.list_to_bin()

    FileHandler.write(file_handler, replay_binary)
    FileHandler.finalize(file_handler, state.game_info)
  end

  @spec save_event_to_state(binary(), State.t(), binary()) :: State.t()
  defp save_event_to_state(event, %State{} = state, cursor) do
    case state.chunks do
      [{^cursor, events} | rest] ->
        Map.put(state, :chunks, [{cursor, [event | events]} | rest])

      _ ->
        Map.put(state, :chunks, [{cursor, [event]} | state.chunks])
    end
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
