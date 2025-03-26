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
  def process_replay_event_data(<<>>, state) do
    {:ok, state, <<>>}
  end

  def process_replay_event_data(
        <<@network_message, rest::binary>>,
        state
      ) do
    {:ok, state, rest}
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
      {:ok, file_manager} =
        Slippi.ReplayFileManager.start_link(%{
          console_nickname: state.wii.nickname,
          start_time: DateTime.utc_now()
        })

      event_data =
        <<0x35, payload_len::unsigned-integer-size(8), payload::binary-size(payload_len - 1)>>

      Slippi.ReplayFileManager.write_event(file_manager, event_data)

      payload_sizes =
        Slippi.Connection.MessageSizesParser.process_message_sizes(payload, payload_len)

      updated_state = %{state | payload_sizes: payload_sizes, file_manager: file_manager}
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

    # Extract the payload and rest of the data
    <<payload::binary-size(payload_len), rest::binary>> = payload
    event_data = <<command>> <> payload

    if state.file_manager do
      Slippi.ReplayFileManager.write_event(state.file_manager, event_data)
    end

    {:ok, updated_state} = process_replay_event(event_data, state)

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
        <<0x10, _payload::binary>> = event,
        state
      ) do
    {:ok, state}
  end

  def process_replay_event(
        <<0x36, payload::binary>>,
        state
      ) do
    # Parse player data from the game start payload
    %{players: players, stage_id: stage_id} =
      Slippi.Parser.MessageParser.parse_message(<<0x36, payload::binary>>)

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

    characters =
      players
      |> Enum.filter(fn player -> player.type != 3 end)
      |> Enum.map(fn player -> player.character_id end)

    APICommunication.post_replay_started_event(%{
      startedAt: System.system_time(:millisecond),
      characterIds: characters,
      stageId: stage_id,
      console: state.wii
    })

    ConnLogger.info("New game started on stage #{stage_id}")

    updated_state = %{state | metadata: %{state.metadata | players: player_state}}

    {:ok, updated_state}
  end

  def process_replay_event(
        <<0x38, payload::binary>>,
        state
      ) do
    %{
      frame: frame,
      player_index: player_index,
      is_follower: is_follower,
      internal_character_id: internal_character_id
    } =
      Slippi.Parser.MessageParser.parse_message(<<0x38, payload::binary>>)

    if is_follower do
      {:ok, state}
    else
      prev_player = state.metadata.players[player_index]

      updated_player =
        prev_player
        |> Map.update(:character_usage, %{internal_character_id => 1}, fn usage ->
          Map.update(usage, internal_character_id, 1, &(&1 + 1))
        end)

      updated_players = Map.put(state.metadata.players, player_index, updated_player)

      updated_state =
        Map.put(state, :metadata, %{state.metadata | players: updated_players, last_frame: frame})

      {:ok, updated_state}
    end
  end

  def process_replay_event(
        <<0x39, _payload::binary>>,
        state
      ) do
    ConnLogger.info("Game ended! #{inspect(state.metadata)}")

    if state.file_manager do
      {:ok, file_path} = Slippi.ReplayFileManager.finalize(state.file_manager, state.metadata)
      Logger.info("File saved to #{file_path}")
    end

    # TODO: Post replay ended event with metadata and file
    {:ok, state}
  end

  def process_replay_event(
        <<_command::unsigned-integer-size(8), _payload::binary>>,
        state
      ) do
    {:ok, state}
  end
end
