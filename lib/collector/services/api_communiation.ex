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
          key: String.t(),
          wii: WiiConsole.t(),
          started_at: non_neg_integer(),
          stage_id: non_neg_integer(),
          player_1: %{
            character_id: non_neg_integer(),
            tag: String.t(),
            skin: non_neg_integer()
          },
          player_2: %{
            character_id: non_neg_integer(),
            tag: String.t(),
            skin: non_neg_integer()
          }
        }

  @type game_ended_event :: %{
          key: String.t(),
          path: String.t()
        }

  # Client API
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec game_started(game_started_event()) :: :ok
  def game_started(data) do
    GenServer.cast(__MODULE__, {:game_started, data})
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
  def handle_cast({:game_started, data}, state) do
    url = "#{Collector.Config.api_base_url()}/api/replay/start"

    headers = [
      {"Content-Type", "application/json"},
      {"x-collector-token", state.collector_token},
      {"x-vercel-protection-bypass", Collector.Config.vercel_bypass_token()}
    ]

    data = %{
      key: data.key,
      startedAt: data.started_at,
      stageId: data.stage_id,
      player1: build_player_data(data.player_1),
      player2: build_player_data(data.player_2),
      wiiMacAddress: data.wii.mac
    }

    Logger.debug("Game started event data: #{inspect(data)}")

    with {:ok, body} <- Jason.encode(data),
         {:ok, response} <- post_request(url, body, headers),
         {:ok, response_body} <- Jason.decode(response.body),
         Collector.Services.WsIngestorCommunication.game_started(data.key) do
      Logger.debug("Game started event posted successfully. Response: #{inspect(response_body)}")
      {:noreply, state}
    else
      {:error, reason} ->
        Logger.error("Failed to post game started event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  @spec handle_cast({:game_ended, game_ended_event()}, state()) :: {:noreply, state()}
  def handle_cast({:game_ended, data}, state) do
    url = "#{Collector.Config.api_base_url()}/api/replay/finish"

    headers = [
      {"x-collector-token", state.collector_token},
      {"x-vercel-protection-bypass", Collector.Config.vercel_bypass_token()}
    ]

    form =
      {:multipart,
       [
         {"key", data.key, {"form-data", [name: "key"]}, [{"Content-Type", "text/plain"}]},
         {:file, data.path,
          {"form-data", [{:name, "file"}, {:filename, Path.basename(data.path)}]}, []}
       ]}

    with {:ok, _response} <-
           post_request(
             url,
             form,
             headers
           ),
         Collector.Services.WsIngestorCommunication.game_ended(data.key) do
      Logger.debug("Game ended event posted successfully.")
      {:noreply, state}
    else
      {:error, reason} ->
        Logger.error("Failed to post game ended event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp post_request(url, body, headers) do
    case HTTPoison.post(url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200} = response} ->
        {:ok, response}

      {:error, %HTTPoison.Error{} = error} ->
        Logger.debug("Error posting request: #{inspect(error)}")
        {:error, error}

      {:ok, %HTTPoison.Response{status_code: 401} = response} ->
        Logger.debug("Failed to post request: UNAUTHORIZED", response: response)
        {:error, response}

      {:ok, %HTTPoison.Response{status_code: 400} = response} ->
        Logger.debug("Failed to post request: BAD REQUEST", response: response)
        {:error, response}

      _ ->
        {:error, "Unknown error"}
    end
  end

  defp build_player_data(player) do
    %{
      characterId: player.character_id,
      tag: player.tag,
      skin: player.skin
    }
  end
end
