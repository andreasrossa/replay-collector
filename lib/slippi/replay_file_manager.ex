defmodule Slippi.ReplayFileManager do
  use GenServer
  require Logger
  alias Slippi.Connection.Logger, as: ConnLogger

  @type opts :: %{
          console_nickname: String.t(),
          start_time: DateTime.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec write_event(pid(), binary()) :: :ok
  def write_event(pid, event) do
    GenServer.cast(pid, {:write_event, event})
  end

  def finalize(pid, metadata) do
    GenServer.cast(pid, {:finalize, metadata})
  end

  # Server

  @impl true
  def init(opts) do
    file_path = create_new_replay_file(opts)
    ConnLogger.info("Created new replay file: #{file_path}")
    {:ok, %{file_path: file_path}}
  end

  @impl true
  def handle_cast({:write_event, event}, state) do
    File.write!(state.file_path, event, [:append, :binary])
    {:noreply, state}
  end

  @impl true
  def handle_cast({:finalize, metadata}, state) do
    ConnLogger.info("Finalizing replay file: #{state.file_path}")

    Task.Supervisor.start_child(
      Slippi.TaskSupervisor,
      fn -> post_process_replay_file(state.file_path, metadata) end
    )

    {:stop, :normal, state}
  end

  @impl true
  def terminate(reason, _state) do
    ConnLogger.debug("ReplayFileManager terminated: #{reason}")
    :ok
  end

  # Utils

  defp create_new_replay_file(opts) do
    timestamp = DateTime.to_unix(opts.start_time)
    nickname = opts.console_nickname |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    replay_dir = Application.get_env(:collector, :replay_directory, "replays")
    File.mkdir_p!(replay_dir)
    path = Path.join(replay_dir, "#{nickname}_#{timestamp}.bin")
    :ok = File.write!(path, get_file_header(), [:binary])
    path
  end

  defp get_file_header() do
    <<"{U", 3, "raw[$U#l", 0, 0, 0, 0>>
  end

  @spec post_process_replay_file(String.t(), Slippi.ConsoleConnection.metadata()) :: :ok
  defp post_process_replay_file(file_path, metadata) do
    ConnLogger.info(
      "Post-processing replay file: #{file_path} with metadata: #{inspect(metadata)}"
    )

    footer =
      build_footer_start(metadata)
      |> add_players_data(metadata.players)
      |> add_footer_end()

    # Write the footer
    File.write!(file_path, footer, [:append, :binary])
  end

  defp build_footer_start(metadata) do
    start_time_str = DateTime.to_iso8601(metadata.start_time)

    <<"U", 8, "metadata{", "U", 7, "startAtSU", byte_size(start_time_str), start_time_str::binary,
      "U", 9, "lastFramel", metadata.last_frame::signed-integer-size(32), "U", 11,
      "consoleNickSU", byte_size(metadata.console_nickname), metadata.console_nickname::binary,
      "U", 7, "players{">>
  end

  defp add_players_data(footer, players) do
    Enum.reduce(players, footer, fn {player_index, player}, acc ->
      acc =
        <<acc::binary, "U", byte_size(<<player_index::unsigned-integer-size(32)>>),
          "#{player_index}{", "U", 10, "characters{">>

      # Add character data
      acc =
        Enum.reduce(player.character_usage, acc, fn {character_id, usage}, chars_acc ->
          <<chars_acc::binary, "U", byte_size(<<character_id::unsigned-integer-size(32)>>),
            "#{character_id}l", usage::unsigned-integer-size(32)>>
        end)

      # Add player names
      <<acc::binary, "}", "U", 5, "names{", "U", 7, "netplaySU", byte_size(player.names.netplay),
        player.names.netplay::binary, "U", 4, "codeSU", byte_size(player.names.code),
        player.names.code::binary, "}}">>
    end)
  end

  defp add_footer_end(footer) do
    <<footer::binary, "}", "U", 8, "playedOnSU", 7, "network", "}}">>
  end
end
