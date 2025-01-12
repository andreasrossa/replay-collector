defmodule Collector.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    children = [
      Slippi.ConnectionScanner,
      {Registry, keys: :unique, name: Collector.WiiRegistry},
      {DynamicSupervisor, name: Collector.WiiConnectionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
