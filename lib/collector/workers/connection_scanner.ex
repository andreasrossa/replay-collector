defmodule Slippi.ConnectionScanner do
  use GenServer
  require Logger

  @discovery_port 20582

  # Client API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop_scanning do
    GenServer.cast(__MODULE__, :stop_scanning)
  end

  # Server callbacks
  @impl true
  def init(_opts) do
    case :gen_udp.open(@discovery_port, [
           :binary,
           {:active, true},
           {:reuseaddr, true},
           {:ip, {0, 0, 0, 0}}
         ]) do
      {:ok, socket} ->
        Logger.info("Scanning for Wii consoles on port :#{@discovery_port}")
        {:ok, %{socket: socket}}

      {:error, reason} ->
        Logger.error("Failed to open UDP socket for console discovery: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def handle_cast(:stop_scanning, state) do
    if state.socket do
      :gen_udp.close(state.socket)
    end

    {:noreply, %{state | socket: nil}}
  end

  @impl true
  def handle_info({:udp, _socket, ip, _port, message}, state) do
    case parse_message(message, ip) do
      {:ok, console} ->
        handle_discovered_console(console)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # Private functions
  defp parse_message(message, ip) do
    case message do
      <<"SLIP_READY", mac::binary-size(6), nickname::binary-size(32), _rest::binary>> ->
        {:ok,
         %Slippi.WiiConsole{
           mac: format_mac_address(mac),
           nickname: extract_nickname(nickname),
           ip: format_ip(ip)
         }}

      _ ->
        :error
    end
  end

  defp format_mac_address(mac) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
  end

  defp extract_nickname(nickname) do
    nickname
    |> :binary.bin_to_list()
    |> Enum.take_while(&(&1 != 0))
    |> List.to_string()
  end

  defp format_ip(ip_tuple) do
    ip_tuple
    |> :inet.ntoa()
    |> to_string()
  end

  defp handle_discovered_console(console) do
    # lookup console in registry:
    case Registry.lookup(Collector.WiiRegistry, console.mac) do
      [{_pid, _}] ->
        :ok

      [] ->
        # start a new connection and register it
        {:ok, _connection} =
          DynamicSupervisor.start_child(
            Collector.WiiConnectionSupervisor,
            {Collector.Workers.ConsoleConnection, console}
          )
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Connection scanner terminated: #{inspect(reason)}")

    if state.socket do
      :gen_udp.close(state.socket)
    end

    :ok
  end
end
