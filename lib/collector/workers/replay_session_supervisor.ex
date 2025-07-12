defmodule Collector.Workers.ReplaySessionSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new ReplaySession with its own session_id, registered in the Registry.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  def start_session() do
    # generate a new session_id
    session_id = UUID.uuid4()

    # kick off the GenServer; it will register itself under that id
    DynamicSupervisor.start_child(__MODULE__, {Collector.Workers.ReplaySession, session_id})
  end
end
