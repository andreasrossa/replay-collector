defmodule Collector.Workers.FileHandler do
  use GenServer
  require Logger

  @type state :: %{
          file_path: String.t()
        }

  # client API
  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  def write_event(pid, event) do
    GenServer.cast(pid, {:write_event, event})
  end

  def finalize(pid, metadata) do
    GenServer.cast(pid, {:finalize, metadata})
  end

  def cleanup(pid) do
    GenServer.call(pid, :cleanup)
  end

  # server callbacks

  @impl true
  def init(state) do
    file_path = create_new_replay_file(state)

    {:ok, %{file_path: file_path}}
  end

  @impl true
  def handle_cast({:write_event, event}, state) do
    File.write!(state.file_path, event, [:append, :binary])
    {:noreply, state}
  end

  @impl true
  def handle_cast({:finalize, metadata}, state) do
    Collector.Workers.FileHandler.PostProcessor.post_process_replay_file(
      state.file_path,
      metadata
    )

    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:cleanup, _from, state) do
    File.rm!(state.file_path)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(reason, state) do
    # Only remove the file on abnormal termination or when cleanup was called
    # Don't remove file on normal termination after finalize
    if reason != :normal && state.file_path && File.exists?(state.file_path) do
      File.rm!(state.file_path)
    end

    :ok
  end

  # utils
  defp get_file_header() do
    <<"{U", 3, "raw[$U#l", 0, 0, 0, 0>>
  end

  defp create_new_replay_file({start_time, console_nickname}) do
    timestamp = start_time
    nickname = console_nickname |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    replay_dir = Collector.Config.replay_directory()

    Logger.info("Creating new replay file in #{replay_dir}")

    case File.mkdir_p(replay_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to create replay directory: #{inspect(reason)}")
        raise "Failed to create replay directory: #{inspect(reason)}"
    end

    path = Path.join(replay_dir, "#{nickname}_#{timestamp}.slp")

    case File.write(path, get_file_header(), [:binary]) do
      :ok ->
        path

      {:error, reason} ->
        Logger.error("Failed to write file header: #{inspect(reason)}")
        raise "Failed to write file header: #{inspect(reason)}"
    end
  end
end
