defmodule Collector.Workers.ReplayProcessor do
  alias Collector.Workers.ReplayProcessor.EventHandler
  alias Slippi.WiiConsole
  alias Collector.Utils.ConsoleLogger, as: ConnLogger
  alias Collector.Workers.FileHandler

  @moduledoc """
  GenServer that processes incoming Slippi messages.
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
          lras: non_neg_integer() | nil,
          start_time: DateTime.t() | nil
        }

  @type state :: %{
          game_id: non_neg_integer() | nil,
          status: :idle | :ongoing | :done,
          wii_console: WiiConsole.t(),
          buffer: binary(),
          cursor: binary(),
          payload_sizes: map(),
          file_manager: pid(),
          file_manager_ref: reference(),
          game_info: game_info()
        }

  @type message :: %{
          data: binary(),
          pos: binary(),
          nextPos: binary(),
          forcePos: boolean()
        }

  @network_message "HELO\0"
  # 5MB
  @max_buffer_size 1024 * 1024 * 5

  # client API
  def start_link(wii_console, opts \\ []) do
    GenServer.start_link(__MODULE__, wii_console, opts)
  end

  @spec process_message(pid(), binary()) :: :ok
  def process_message(pid, message) do
    GenServer.cast(pid, {:process_message, message})
  end

  # server callbacks
  @impl true
  def init(wii_console) do
    ConnLogger.set_wii_context(wii_console)

    # Start the file handler here with initial state
    start_time = DateTime.utc_now()
    {:ok, file_manager} = FileHandler.start_link({start_time, wii_console.nickname})

    file_manager_ref = Process.monitor(file_manager)

    {:ok,
     %{
       wii_console: wii_console,
       game_id: nil,
       status: :idle,
       buffer: <<>>,
       cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
       payload_sizes: %{},
       file_manager: file_manager,
       game_info: init_game_info(),
       file_manager_ref: file_manager_ref
     }}
  end

  @impl true
  def handle_cast({:process_message, message}, state) do
    case handle_replay_message(message, state) do
      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{file_manager_ref: ref} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{file_manager_ref: ref} = state) do
    ConnLogger.warning("File handler process crashed: #{inspect(reason)}")
    {:stop, :file_handler_crash, state}
  end

  @impl true
  def handle_info(msg, state) do
    ConnLogger.warning("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @doc """
  Handles a replay message containing game data.
  """
  @spec handle_replay_message(message(), state()) :: {:ok, state()} | {:error, atom()}
  def handle_replay_message(
        %{"data" => data, "pos" => read_pos, "nextPos" => next_pos, "forcePos" => force_pos},
        state
      ) do
    binary_data = :binary.list_to_bin(data)
    read_pos_binary = :binary.list_to_bin(read_pos)
    next_pos_binary = :binary.list_to_bin(next_pos)

    FileHandler.write_event(state.file_manager, binary_data)

    with {:ok, next_cursor} <-
           validate_cursor(read_pos_binary, next_pos_binary, force_pos, state),
         {:ok, updated_state, rest} <-
           process_replay_event_data(
             <<state.buffer::binary, binary_data::binary>>,
             %{state | cursor: next_cursor}
           ) do
      {:ok, %{updated_state | buffer: rest}}
    else
      {:error, :position_mismatch} ->
        {:error, :position_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Processes different types of replay events based on command byte.
  """
  @spec process_replay_event_data(binary(), state()) ::
          {:ok, state(), binary()} | {:error, atom()}
  def process_replay_event_data(<<>>, state) do
    {:ok, state, <<>>}
  end

  def process_replay_event_data(
        <<@network_message, rest::binary>>,
        state
      ) do
    {:ok, state, rest}
  end

  # special case for payload sizes, needs to extract the payload length first
  # also, other commands depend on this one to be processed first
  def process_replay_event_data(
        <<0x35, payload_len::unsigned-integer-size(8), payload::binary>>,
        state
      )
      when payload_len > 0 and byte_size(payload) >= payload_len - 1 do
    <<payload::binary-size(payload_len - 1), rest::binary>> = payload

    case EventHandler.handle_payload_sizes(
           <<0x35, payload_len::unsigned-integer-size(8), payload::binary>>,
           state
         ) do
      {:ok, updated_state} ->
        process_replay_event_data(rest, updated_state)

      {:error, _} = error ->
        error
    end
  end

  def process_replay_event_data(binary, state) do
    with {:ok, command, remaining} <- extract_command(binary),
         {:ok, payload_size} <- get_payload_size(command, state),
         {:ok, payload, rest} <- extract_payload(remaining, payload_size) do
      process_command(command, payload, rest, state)
    else
      {:incomplete, _} ->
        # Not enough data yet, keep in buffer and wait for more
        {:ok, state, binary}

      {:error, reason} ->
        handle_parsing_error(reason, state, binary)
    end
  end

  defp extract_command(<<command::unsigned-integer-size(8), rest::binary>>),
    do: {:ok, command, rest}

  defp extract_command(_), do: {:incomplete, :command}

  defp extract_payload(binary, size) when byte_size(binary) >= size do
    <<payload::binary-size(size), rest::binary>> = binary
    {:ok, payload, rest}
  end

  defp extract_payload(_, _), do: {:incomplete, :payload}

  defp get_payload_size(command, state) do
    case state.payload_sizes[command] do
      nil ->
        ConnLogger.warning("Unknown command: #{command}")
        {:error, :unknown_command}

      size ->
        {:ok, size}
    end
  end

  defp process_command(command, payload, rest, state) do
    case do_process_command(command, payload, state) do
      {:ok, updated_state} ->
        process_replay_event_data(rest, updated_state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_process_command(0x36, payload, state) do
    ConnLogger.debug("Processing game start event")

    case EventHandler.handle_game_start(<<0x36, payload::binary>>, state) do
      {:ok, updated_state} ->
        {:ok, updated_state}

      {:error, reason} ->
        ConnLogger.error("Error processing game start event: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_process_command(0x38, payload, state) do
    case EventHandler.handle_post_frame_update(<<0x38, payload::binary>>, state) do
      {:ok, updated_state} ->
        {:ok, updated_state}

      {:error, reason} ->
        ConnLogger.error("Error processing post frame update event: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_process_command(0x39, payload, state) do
    case EventHandler.handle_game_ended(<<0x39, payload::binary>>, state) do
      {:ok, updated_state} ->
        {:ok, updated_state}
    end
  end

  defp do_process_command(command, payload, state) do
    case EventHandler.handle_generic_event(<<command, payload::binary>>, state) do
      {:ok, updated_state} ->
        {:ok, updated_state}
    end
  end

  # Implement timeouts and buffer size limits
  defp handle_parsing_error(reason, state, binary) do
    if byte_size(binary) > @max_buffer_size do
      # Discard buffer if it gets too large
      ConnLogger.error("Buffer overflow, discarding data: #{inspect(reason)}")
      {:ok, %{state | buffer: <<>>}, <<>>}
    else
      # Log error but preserve buffer
      ConnLogger.warning("Buffer parsing error: #{inspect(reason)}")
      {:ok, state, binary}
    end
  end

  @doc """
  Compares the position of an incoming message with the current position according to the state.

  ## Parameters
  - `read_cursor`: The current position according to the read buffer
  - `next_cursor`: The next position according to the next buffer
  - `force_pos`: Whether to force the position
  - `state`: The current state of the processor

  ## Returns
  - `{:ok, binary()}` if the cursor is valid
  - `{:error, atom()}` if the cursor is invalid
  """
  @spec validate_cursor(binary(), binary(), boolean(), state()) ::
          {:ok, binary()} | {:error, atom()}
  def validate_cursor(read_cursor, next_cursor, force_pos, state) do
    current_cursor = state.cursor

    cond do
      # Force position for overflow handling
      force_pos ->
        {:ok, next_cursor}

      # Normal case - positions match
      current_cursor == read_cursor ->
        {:ok, next_cursor}

      # Initial position
      current_cursor == <<0, 0, 0, 0, 0, 0, 0, 0>> ->
        {:ok, next_cursor}

      # Position mismatch error
      current_cursor != read_cursor ->
        ConnLogger.error(
          "Position mismatch. Expected: #{inspect(current_cursor)}, Got: #{inspect(read_cursor)}"
        )

        {:error, :position_mismatch}
    end
  end

  defp init_game_info do
    %{
      start_time: nil,
      last_frame: nil,
      players: %{},
      stage_id: nil,
      characters: [],
      game_end_type: nil,
      lras: nil
    }
  end
end
