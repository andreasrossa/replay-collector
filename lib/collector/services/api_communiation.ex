defmodule Collector.Services.APICommunication do
  @moduledoc """
  API communication service for the Collector application.
  """
  alias Slippi.WiiConsole

  use GenServer
  use HTTPoison.Base
  require Logger

  @type state :: %{
          collector_token: String.t(),
          queue: [any()]
        }

  @type game_started_event :: %{
          id: String.t(),
          startedAt: non_neg_integer(),
          characterIds: [non_neg_integer()],
          stageId: non_neg_integer(),
          console: WiiConsole.t()
        }

  @type game_ended_event :: %{
          id: String.t(),
          path: String.t()
        }

  # Client API
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec game_started(game_started_event()) :: {:ok, non_neg_integer()} | {:error, any()}
  def game_started(data) do
    GenServer.call(__MODULE__, {:game_started, data})
  end

  @spec game_ended(game_ended_event()) :: :ok
  def game_ended(data) do
    GenServer.cast(__MODULE__, {:game_ended, data})
  end

  # Server callbacks
  @impl true
  def init(:ok) do
    Logger.info("API Communication service initialized")

    {:ok,
     %{
       collector_token: Collector.Config.collector_token(),
       queue: []
     }}
  end

  @impl true
  def handle_call({:game_started, data}, _from, state) do
    case post_game_started(data, state.collector_token) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  @spec handle_cast({:game_ended, game_ended_event()}, state()) :: {:noreply, state()}
  def handle_cast({:game_ended, data}, state) do
    case post_game_ended(data, state.collector_token) do
      :ok ->
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @spec post_game_started(game_started_event(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, any()}
  defp post_game_started(data, token) do
    url = "#{Collector.Config.api_base_url()}/api/replay/start"

    headers = [
      {"Content-Type", "application/json"},
      {"x-collector-token", token}
    ]

    data = %{
      startedAt: data.startedAt,
      characterIds: data.characterIds,
      stageId: data.stageId,
      wiiMacAddress: data.console.mac,
      id: data.id
    }

    with {:ok, body} <- Jason.encode(data),
         {:ok, response} <- post_request(url, body, headers),
         {:ok, response_body} <- Jason.decode(response.body) do
      Logger.info("Game started event posted successfully. Response: #{inspect(response_body)}")
      {:ok, response_body}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec post_game_ended(game_ended_event(), String.t()) :: :ok | {:error, any()}
  defp post_game_ended(data, token) do
    url = "#{Collector.Config.api_base_url()}/api/replay/end"

    headers = [
      {"Content-Type", "multipart/form-data"},
      {"x-collector-token", token}
    ]

    with {:ok, file_content} <- File.read(data.path),
         {:ok, _response} <-
           post_request(
             url,
             {:multipart,
              [
                {:file, file_content, {"form-data", [name: "file", filename: "replay.slp"]}, []},
                {"id", data.id}
              ]},
             headers
           ) do
      Logger.info("Game ended event posted successfully.")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to post game ended event: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp post_request(url, body, headers) do
    case HTTPoison.post(url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200} = response} ->
        {:ok, response}

      {:error, %HTTPoison.Error{} = error} ->
        Logger.error("Error posting request: #{inspect(error)}")
        {:error, error}

      {:ok, %HTTPoison.Response{status_code: 401} = response} ->
        Logger.error("Failed to post request: UNAUTHORIZED", response: response)
        {:error, response}

      {:ok, %HTTPoison.Response{status_code: 400} = response} ->
        Logger.error("Failed to post request: BAD REQUEST", response: response)
        {:error, response}
    end
  end
end
