defmodule Collector.Application do
  use Application

  def start(_type, _args) do
    Collector.Supervisor.start_link(name: Collector.Supervisor)
  end
end
