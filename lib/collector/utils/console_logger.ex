defmodule Collector.Utils.ConsoleLogger do
  @moduledoc """
  Custom logger for Slippi connections using Logger metadata.
  """
  alias Slippi.WiiConsole
  require Logger

  @doc """
  Sets Wii metadata for the current process.
  All subsequent logs from this process will include this metadata.
  Call this once when initializing your process or when Wii information changes.
  """
  @spec set_wii_context(WiiConsole.t()) :: :ok
  def set_wii_context(wii_console) do
    Logger.metadata(
      wii_nickname: wii_console.nickname || "unknown",
      wii_ip: wii_console.ip || "unknown"
    )
  end

  @doc """
  Clears Wii metadata from the current process.
  """
  def clear_wii_context do
    Logger.metadata(wii_nickname: nil, wii_ip: nil)
  end

  @doc """
  Logs a message with the appropriate level.
  Uses metadata already set for the process plus any additional metadata provided.
  """
  def log(level, message, additional_metadata \\ []) do
    Logger.log(level, message, additional_metadata)
  end

  @doc "Log at debug level"
  def debug(message, metadata \\ []), do: log(:debug, message, metadata)

  @doc "Log at info level"
  def info(message, metadata \\ []), do: log(:info, message, metadata)

  @doc "Log at warning level"
  def warning(message, metadata \\ []), do: log(:warning, message, metadata)

  @doc "Log at error level"
  def error(message, metadata \\ []), do: log(:error, message, metadata)
end
