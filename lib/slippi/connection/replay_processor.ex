defmodule Slippi.Connection.ReplayProcessor do
  @moduledoc """
  Processes replay data and events from Slippi connections.
  """
  require Logger

  @doc """
  Handles a replay message containing game data.
  """
  @spec handle_replay_message(map(), map()) :: {:noreply, map()} | {:error, atom()}
  def handle_replay_message(
        %{"data" => data, "pos" => read_pos, "nextPos" => next_pos, "forcePos" => force_pos},
        state
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
          Logger.error(
            "Position mismatch. Expected: #{inspect(current_cursor)}, Got: #{inspect(read_pos_binary)}"
          )

          {:error, :position_mismatch}

        # Normal case - positions match
        current_cursor == read_pos_binary ->
          updated_state = put_in(state.connection_details.game_data_cursor, next_pos_binary)
          {:ok, updated_state}
      end

    case result do
      {:ok, updated_state} -> process_replay_event(binary_data, updated_state)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Processes different types of replay events based on command byte.
  """
  @spec process_replay_event(binary(), map()) :: {:noreply, map()}
  def process_replay_event(<<0x35, rest::binary>>, state) do
    Logger.debug("Processing message sizes: #{inspect(rest, limit: 20, base: :hex)}")
    payload_sizes = Slippi.Connection.MessageSizesParser.process_message_sizes(rest)
    Logger.debug("Payload sizes: #{inspect(payload_sizes)}")
    {:noreply, %{state | payload_sizes: payload_sizes}}
  end

  def process_replay_event(<<0x36, rest_binary::binary>>, state) do
    payload_size = state.payload_sizes[54]
    <<event_data::binary-size(payload_size), _rest::binary>> = rest_binary

    try do
      ubjson_data = UBJSON.decode(event_data)
      Logger.debug("UBJSON data: #{inspect(ubjson_data)}")
    catch
      :error, reason ->
        Logger.error("Error decoding UBJSON: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def process_replay_event(<<0x39, payload::binary>>, state) do
    Logger.debug("Processing game end event: #{inspect(payload, limit: 20, base: :hex)}")
    {:noreply, state}
  end

  def process_replay_event(<<_command, _rest::binary>>, state) do
    # Logger.debug("Unknown command: #{inspect(command, base: :hex)}")
    {:noreply, state}
  end
end
