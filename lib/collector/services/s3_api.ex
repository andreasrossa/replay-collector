defmodule Collector.Services.S3Api do
  use GenServer

  require Logger

  @bucket "replay-browser"

  # Client API
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def upload_file(path, name) do
    GenServer.cast(__MODULE__, {:upload_file, path, name})
  end

  # Server callbacks
  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:upload_file, path, name}, state) do
    Logger.info("Uploading file to S3: #{name}")

    with {:ok, file_content} <- File.read(path),
         %ExAws.Operation.S3{} <- ExAws.S3.put_object(@bucket, name, file_content) do
      Logger.info("File uploaded to S3: #{name}")
    else
      {:error, reason} ->
        Logger.error("Failed to upload file to S3: #{name}, reason: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
