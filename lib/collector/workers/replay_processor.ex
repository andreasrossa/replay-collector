defmodule Collector.Workers.ReplayProcessor do
  alias Collector.Services.APICommunication
  alias Slippi.WiiConsole
  alias Collector.Utils.ConsoleLogger, as: ConnLogger
  alias Collector.Workers.FileHandler
  alias Slippi.Parser.GameStartParser
  alias Slippi.Parser.GameEndParser
  alias Slippi.Parser.PostFrameUpdateParser

  @moduledoc """
  GenServer that processes incoming Slippi events.
  This module is responsible for:
  - Writing incoming replay data to disk
  - Doing any processing required for the data
  - Sending game start and end events to the API
  """

  use GenServer

  @type game_info :: %{
          characters: [non_neg_integer()],
          stage_id: non_neg_integer(),
          players: map(),
          last_frame: non_neg_integer() | nil,
          game_end_type: non_neg_integer() | nil,
          lras: non_neg_integer() | nil
        }

  @type state :: %{
          wii_console: WiiConsole.t(),
          game_id: String.t(),
          start_time: non_neg_integer(),
          file_manager: pid(),
          file_manager_ref: reference(),
          game_info: game_info() | nil
        }

  ##############
  # CLIENT API #
  ##############

  @spec start_link(WiiConsole.t()) :: {:ok, pid()} | {:error, any()}
  def start_link(wii_console, opts \\ []) do
    GenServer.start_link(__MODULE__, wii_console, opts)
  end

  @spec process_event(pid(), binary()) :: :ok
  def process_event(pid, event) do
    GenServer.cast(pid, {:process_event, event})
  end

  ####################
  # SERVER CALLBACKS #
  ####################
  @impl true
  @spec init(WiiConsole.t()) :: {:ok, state()} | {:error, any()}
  def init(wii_console) do
    start_time = System.system_time(:millisecond)

    ConnLogger.set_wii_context(wii_console)

    # Start the file handler here with initial state
    {:ok, file_manager} = FileHandler.start_link({start_time, wii_console.nickname})

    file_manager_ref = Process.monitor(file_manager)

    {:ok,
     %{
       wii_console: wii_console,
       game_id: UUID.uuid4(),
       start_time: start_time,
       file_manager: file_manager,
       file_manager_ref: file_manager_ref,
       game_info: nil
     }}
  end

  @impl true
  def handle_cast({:process_event, event}, state) do
    FileHandler.write_event(state.file_manager, event)

    case handle_replay_event(event, state) do
      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:game_ended, updated_state} ->
        Collector.Workers.FileHandler.finalize(updated_state.file_manager, %{
          start_time: updated_state.start_time,
          last_frame: updated_state.game_info.last_frame,
          players: updated_state.game_info.players,
          console_nickname: updated_state.wii_console.nickname
        })

        {:stop, :normal, updated_state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{file_manager_ref: ref} = state) do
    ConnLogger.warning("File handler process crashed: #{inspect(reason)}")
    {:stop, :file_handler_crash, state}
  end

  def handle_replay_event(<<0x36, _payload::binary>> = event, state) do
    case GameStartParser.parse_game_start(event) do
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
               },
               character_id: player.character_id,
               percent: 0,
               stocks: 4
             }}
          end)
          |> Map.new()

        character_ids =
          players
          # 3 is the empty player type
          |> Enum.filter(fn player -> player.type != 3 end)
          |> Enum.map(fn player -> player.character_id end)

        game_info = %{
          stage_id: stage_id,
          characters: character_ids,
          players: player_state,
          last_frame: nil,
          game_end_type: nil,
          lras: nil
        }

        player_1 = build_player_data(Enum.at(players, 0))
        player_2 = build_player_data(Enum.at(players, 1))

        try do
          APICommunication.game_started(%{
            key: state.game_id,
            wii: state.wii_console,
            started_at: state.start_time,
            stage_id: stage_id,
            player_1: player_1,
            player_2: player_2
          })
        rescue
          error ->
            ConnLogger.error("Error sending game started event: #{inspect(error)}")
        end

        {:ok, %{state | game_info: game_info}}

      {:error, reason} ->
        ConnLogger.debug("Error parsing game start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle_replay_event(<<0x38, _payload::binary>> = event, state) do
    if state.game_info == nil do
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

            previous_stocks = player.stocks
            previous_percent = player.percent

            updated_player =
              player
              |> Map.update(:character_usage, %{internal_character_id => 1}, fn usage ->
                Map.update(usage, internal_character_id, 1, &(&1 + 1))
              end)
              |> Map.put(:percent, percent)
              |> Map.put(:stocks, stocks_remaining)

            updated_players = Map.put(state.game_info.players, player_index, updated_player)

            updated_state =
              Map.put(state, :game_info, %{
                state.game_info
                | players: updated_players,
                  last_frame: frame
              })

            if previous_percent != percent || previous_stocks != stocks_remaining do
              Collector.Services.WsIngestorCommunication.character_state_update(
                state.game_id,
                state.game_info.players[player_index].character_id,
                %{percent: percent, stocks: stocks_remaining}
              )
            end

            {:ok, updated_state}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def handle_replay_event(<<0x39, payload::binary>>, state) do
    case GameEndParser.parse_game_end(payload) do
      {:ok, %{game_end_type: game_end_type, lras: lras}} ->
        updated_state =
          Map.put(state, :game_info, %{
            state.game_info
            | game_end_type: game_end_type,
              lras: lras
          })

        ConnLogger.debug("Game ended. Game info: #{inspect(updated_state.game_info)}")

        APICommunication.game_ended(%{
          key: state.game_id,
          path: FileHandler.get_file_path(updated_state.file_manager)
        })

        {:game_ended, updated_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_replay_event(_event, state) do
    {:ok, state}
  end

  defp build_player_data(player) do
    %{
      character_id: player.character_id,
      tag: player.nametag,
      skin: player.skin
    }
  end
end
