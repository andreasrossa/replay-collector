defmodule APICommunication do
  use HTTPoison.Base
  require Logger

  def post_replay_started_event(data) do
    headers = [
      {"Content-Type", "application/json"},
      {"x-collector-secret",
       "002bc6d1e999a59f951b25786b0b7cdeffcf245f11597ce4c0a78f6a7dc9381681f73e383b8e18c1d2e1f902ca249d9685b2d7140d531a5ad9a138f538e91bb3"}
    ]

    json_body = Jason.encode!(data)

    case HTTPoison.post("http://localhost:3000/api/replay/start", json_body, headers) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
