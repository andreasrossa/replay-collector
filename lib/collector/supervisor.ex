defmodule Collector.Supervisor do
  use Supervisor

  @spec start_link([{:name, atom() | {:global, any()} | {:via, atom(), any()}}]) ::
          :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: Collector.SessionRegistry},
      Slippi.ConnectionScanner
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
