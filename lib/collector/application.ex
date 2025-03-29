defmodule Collector.Application do
  use Application

  @spec start(any(), any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start(_type, _args) do
    Collector.Supervisor.start_link(name: Collector.Supervisor)
  end
end
