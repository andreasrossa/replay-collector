defmodule Slippi.Connection.Handler do
  @moduledoc """
  Handles TCP connection establishment and management for Slippi consoles.
  """
  require Logger
  alias Slippi.ConsoleCommunication

  @default_port 51441

  @doc """
  Establishes a TCP connection to a Wii console.
  """
  @spec connect(Slippi.WiiConsole.t()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect(wii_console) do
    case :gen_tcp.connect(
           String.to_charlist(wii_console.ip),
           @default_port,
           [:binary, active: true, packet: :raw]
         ) do
      {:ok, socket} ->
        case send_handshake(socket) do
          :ok ->
            Logger.info("Connected to Wii at #{wii_console.ip}")
            {:ok, socket}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  Sends the initial handshake message to establish a Slippi connection.
  """
  @spec send_handshake(:gen_tcp.socket()) :: :ok | {:error, term()}
  def send_handshake(socket) do
    :gen_tcp.send(
      socket,
      ConsoleCommunication.generate_handshake(<<0, 0, 0, 0, 0, 0, 0, 0>>, 0, false)
    )
  end

  @doc """
  Sends a message over an established connection.
  """
  @spec send_message(:gen_tcp.socket(), binary()) :: :ok | {:error, term()}
  def send_message(socket, message) do
    :gen_tcp.send(socket, message)
  end

  @doc """
  Closes a connection gracefully.
  """
  @spec close(:gen_tcp.socket() | nil) :: :ok
  def close(nil), do: :ok
  def close(socket), do: :gen_tcp.close(socket)
end
