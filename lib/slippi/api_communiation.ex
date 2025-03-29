defmodule APICommunication do
  use HTTPoison.Base
  require Logger

  @headers [
    {"Content-Type", "application/json"},
    {"x-collector-secret", System.get_env("COLLECTOR_SECRET")}
  ]

  def post_replay_started_event(data) do
    json_body = Jason.encode!(data)

    case HTTPoison.post("http://localhost:3000/api/replay/start", json_body, @headers) do
      {:ok, response} ->
        Logger.info("Replay started event posted successfully.")
        {:ok, response}

      {:error, reason} ->
        Logger.error("Error posting replay started event: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def post_replay_ended_event(data) do
    json_body = Jason.encode!(data)

    case HTTPoison.post("http://localhost:3000/api/replay/end", json_body, @headers) do
      {:ok, response} ->
        Logger.info("Replay ended event posted successfully.")
        {:ok, response}

      {:error, reason} ->
        Logger.error("Error posting replay ended event: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
