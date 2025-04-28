defmodule Collector.Workers.ConsoleConnection.EventExtractor do
  @moduledoc """
  Extracts events from the message stream.
  """
  alias Collector.Workers.ConsoleConnection
  alias Slippi.Parser.PayloadSizesParser
  alias Collector.Utils.ConsoleLogger, as: ConnLogger

  @network_message "HELO\0"

  @doc """
  Processes different types of replay events based on command byte.
  """
  @spec process_replay_event_data(binary(), ConsoleConnection.state()) ::
          {:payload_sizes, map(), binary(), binary()}
          | {:event, byte(), binary(), binary()}
          | {:continue, binary()}
          | {:error, atom()}
  def process_replay_event_data(<<>>, _state) do
    {:continue, <<>>}
  end

  def process_replay_event_data(
        <<@network_message, rest::binary>>,
        _state
      ) do
    {:continue, rest}
  end

  # special case for payload sizes, needs to extract the payload length first
  # also, other commands depend on this one to be processed first
  def process_replay_event_data(
        <<0x35, payload_len::unsigned-integer-size(8), payload::binary>>,
        _state
      )
      when payload_len > 0 and byte_size(payload) >= payload_len - 1 do
    <<payload::binary-size(payload_len - 1), rest::binary>> = payload

    event_data = <<0x35, payload_len::unsigned-integer-size(8), payload::binary>>

    case PayloadSizesParser.parse_payload_sizes(payload) do
      {:ok, payload_sizes} ->
        {:payload_sizes, payload_sizes, event_data, rest}

      {:error, :remaining_bytes_less_than_zero} ->
        {:error, :invalid_payload_sizes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def process_replay_event_data(binary, state) do
    with {:ok, command, remaining} <- extract_command(binary),
         {:ok, payload_size} <- get_payload_size(command, state),
         {:ok, payload, rest} <- extract_payload(remaining, payload_size) do
      {:event, command, payload, rest}
    else
      {:incomplete, _} ->
        # Not enough data yet, keep in buffer and wait for more
        {:continue, binary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_command(<<command::unsigned-integer-size(8), rest::binary>>),
    do: {:ok, command, rest}

  defp extract_command(_), do: {:incomplete, :command}

  defp extract_payload(binary, size) when byte_size(binary) >= size do
    <<payload::binary-size(size), rest::binary>> = binary
    {:ok, payload, rest}
  end

  defp extract_payload(_, _), do: {:incomplete, :payload}

  defp get_payload_size(command, state) do
    case state.payload_sizes[command] do
      nil ->
        {:error, :unknown_command}

      size ->
        {:ok, size}
    end
  end
end
