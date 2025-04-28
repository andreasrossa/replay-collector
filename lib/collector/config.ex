defmodule Collector.Config do
  @moduledoc """
  Centralized configuration access for the Collector application.
  """

  @doc """
  Returns the collector token from the environment.
  Raises if the token is not set.
  """
  def collector_token do
    case Application.get_env(:collector, :collector_token) do
      nil -> raise "COLLECTOR_TOKEN environment variable is not set"
      token -> token
    end
  end

  def api_base_url do
    case Application.get_env(:collector, :api_base) do
      nil -> raise "API_BASE_URL environment variable is not set"
      url -> url
    end
  end

  @spec replay_directory() :: String.t()
  def replay_directory do
    case Application.get_env(:collector, :replay_directory) do
      nil -> raise "REPLAY_DIRECTORY environment variable is not set"
      dir -> dir
    end
  end
end
