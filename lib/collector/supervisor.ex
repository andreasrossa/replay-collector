defmodule Collector.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: Collector.WiiRegistry},
      {DynamicSupervisor, name: Collector.WiiConnectionSupervisor, strategy: :one_for_one},
      # {Redix, name: :redix, host: "localhost", port: 6379},
      Slippi.ConnectionScanner
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
