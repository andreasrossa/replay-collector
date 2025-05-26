defmodule Collector.Services.WsIngestorCommunication do
  @moduledoc """
  Module for communicating with the WS ingestor.
  """

  use GenServer
  alias PhoenixClient.{Socket, Channel, Message}
  require Logger

  @type state :: %{
          socket: pid(),
          channel: pid()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case Socket.start_link(url: Collector.Config.ws_ingestor_url()) do
      {:ok, socket} ->
        {:ok, %{socket: socket, channel: nil}, {:continue, nil}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Client API

  @spec game_started(String.t()) :: :ok
  def game_started(key) do
    GenServer.cast(__MODULE__, {:game_started, key})
  end

  def game_ended(data) do
    GenServer.cast(__MODULE__, {:game_ended, data})
  end

  @spec character_state_update(String.t(), String.t(), %{percent: float(), stocks: integer()}) ::
          :ok
  def character_state_update(key, character_id, data) do
    GenServer.cast(__MODULE__, {:character_state_update, key, character_id, data})
  end

  # Server API

  @impl true
  def handle_continue(_, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  @spec handle_cast({:game_started, String.t()}, state()) :: {:noreply, state()}
  def handle_cast({:game_started, key}, state) do
    message = %{
      payload: %{
        key: key
      }
    }

    case Channel.push(state.channel, "replay_started", message) do
      {:ok, _} ->
        Logger.info("Game started event posted successfully.")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to post game started event to WS ingestor: #{inspect(reason)}")
        {:noreply, state}
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:game_ended, key}, state) do
    message = %{
      payload: %{
        key: key
      }
    }

    case Channel.push(state.channel, "replay_ended", message) do
      {:ok, _} ->
        Logger.info("Game ended event posted successfully.")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to post game ended event to WS ingestor: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  @spec handle_cast(
          {:character_state_update, String.t(), String.t(),
           %{percent: float(), stocks: integer()}},
          state()
        ) :: {:noreply, state()}
  def handle_cast({:character_state_update, key, character_id, data}, state) do
    message = %{
      key: key,
      character_id: character_id,
      payload: %{
        percent: data.percent,
        stocks: data.stocks
      }
    }

    case Channel.push(state.channel, "character_state_update", message) do
      {:ok, _} ->
        Logger.debug(
          "Updated character state: (key: #{key}, character_id: #{character_id}, percent: #{data.percent}, stocks: #{data.stocks})"
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to post percentage updated event to WS ingestor: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:stocks_updated, key, character_id, stock}, state) do
    message = %{
      payload: %{
        key: key,
        character_id: character_id,
        stock: stock
      }
    }

    case Channel.push(state.channel, "stock_update", message) do
      {:ok, _} ->
        Logger.debug(
          "Stocks updated event posted successfully. (key: #{key}, character_id: #{character_id}, stock: #{stock})"
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to post stocks updated event to WS ingestor: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect, state) when is_nil(state.channel) do
    if Socket.connected?(state.socket) do
      Logger.info("Connected to WS ingestor: #{Collector.Config.ws_ingestor_url()}")
      {:ok, _response, channel} = Channel.join(state.socket, "collector:games")
      {:noreply, %{state | channel: channel}}
    else
      Process.send_after(self(), :connect, 1000)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, socket, reason}, state) when socket == state.socket do
    Logger.error("WS ingestor connection closed: #{inspect(reason)}")
    {:stop, reason, state}
  end

  @impl true
  def handle_info(%Message{event: "phx_error", payload: payload}, state) do
    Logger.error("WS ingestor error: #{inspect(payload)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("WS ingestor message: #{inspect(message)}")
    {:noreply, state}
  end
end
