defmodule Collector.Workers.ConsoleConnection.Supervisor do
  @moduledoc """
  Per-console supervisor that manages the connection to a single Wii.

  Children (in order):
    1. ReplaySessionManager - holds authoritative cursor & session state
    2. Socket              - owns TCP connection & handles network I/O

  Strategy: :rest_for_one
    • Socket crash → only Socket restarts
    • Manager crash → both Manager and Socket restart (Manager first)
  """

  use Supervisor
  alias Slippi.WiiConsole

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(WiiConsole.t()) :: Supervisor.on_start()
  def start_link(%WiiConsole{} = wii_console) do
    Supervisor.start_link(__MODULE__, wii_console, name: via_tuple(wii_console.mac))
  end

  # ---------------------------------------------------------------------------
  # Supervisor Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  @spec init(Slippi.WiiConsole.t()) ::
          {:ok,
           {%{
              auto_shutdown: :all_significant | :any_significant | :never,
              intensity: non_neg_integer(),
              period: pos_integer(),
              strategy: :one_for_all | :one_for_one | :rest_for_one
            }, [{any(), any(), any(), any(), any(), any()} | map()]}}
  def init(%WiiConsole{} = wii_console) do
    children = [
      # Order matters for :rest_for_one strategy
      # C1 - Manager (stable, holds cursor)
      {Collector.Workers.ConsoleConnection.ReplayManager, wii_console},

      # C2 - Socket (volatile, handles network)
      {Collector.Workers.ConsoleConnection.Socket, wii_console}
    ]

    # rest_for_one = Socket crashes -> Socket restarts, Manager crashes -> both restart
    Supervisor.init(children, strategy: :rest_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp via_tuple(mac) do
    {:via, Registry, {Collector.SessionRegistry, {:console_supervisor, mac}}}
  end
end
