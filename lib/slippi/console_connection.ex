defmodule Slippi.ConsoleConnection do
  use GenServer
  require Logger

  @default_port 51441

  @type state :: %{
          wii: Slippi.WiiConsole.t(),
          socket: :gen_tcp.socket() | nil
        }

  # Client API
  def start_link(wii_console) do
    GenServer.start_link(__MODULE__, wii_console)
  end

  def send_message(pid, message) do
    GenServer.cast(pid, {:send_message, message})
  end

  def disconnect(pid) do
    GenServer.cast(pid, :disconnect)
  end

  # Server Callbacks
  @impl true
  def init(wii_console) do
    Logger.info("Starting console connection for #{wii_console.nickname}")

    case connect(wii_console) do
      {:ok, socket} ->
        {:ok, %{wii: wii_console, socket: socket}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_cast({:send_message, message}, %{socket: socket} = state) when not is_nil(socket) do
    case :gen_tcp.send(socket, message) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to send message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_message, _message}, state) do
    Logger.warning("Attempted to send message while disconnected")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:disconnect, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    case parse_message(data) do
      {:game_start} ->
        Logger.info("Game start marker detected")

      # Additional game start handling
      {:game_end} ->
        Logger.info("Game end marker detected")

      # Additional game end handling
      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("Connection closed by Wii")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("TCP error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  # Connect to the Wii console
  defp connect(wii_console) do
    case :gen_tcp.connect(String.to_charlist(wii_console.ip), @default_port, [
           :binary,
           active: true,
           packet: :raw
         ]) do
      {:ok, socket} ->
        Logger.info("Connected to Wii at #{wii_console.ip}")
        {:ok, socket}

      {:error, reason} ->
        Logger.error("Failed to connect to Wii: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_message(data) do
    cond do
      <<0x36>> in data -> {:game_start}
      <<0x39>> in data -> {:game_end}
      true -> {:unknown}
    end
  end
end
