defmodule Collector.Workers.ConsoleConnection.EventExtractor do
  @moduledoc """
  Extracts events from the message stream.
  """
  alias Collector.Workers.ConsoleConnection
  alias Slippi.Parser.PayloadSizesParser

  @network_message "HELO\0"

  @doc """
  Processes different types of replay events based on command byte.
  Returns:
  - {:payload_sizes, payload_sizes, event_data, rest}
  - {:event, command, payload, rest}
  - {:continue, rest}
  - {:error, reason}

  Note: event payloads are prepended with the command byte.
  """
  @spec process_replay_event_data(binary(), ConsoleConnection.state()) ::
          {:payload_sizes, map(), binary(), binary()}
          | {:event, byte(), binary(), binary()}
          | {:continue, binary()}
          | {:error, atom()}
  def process_replay_event_data(<<>>, _payload_sizes) do
    {:continue, <<>>}
  end

  def process_replay_event_data(
        <<@network_message, rest::binary>>,
        _payload_sizes
      ) do
    {:continue, rest}
  end

  # special case for payload sizes, needs to extract the payload length first
  # also, other commands depend on this one to be processed first
  def process_replay_event_data(
        <<0x35, payload_len::unsigned-integer-size(8), payload::binary>>,
        _payload_sizes
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

  def process_replay_event_data(binary, payload_sizes) do
    with {:ok, command, remaining} <- extract_command(binary),
         {:ok, payload_size} <- get_payload_size(command, payload_sizes),
         {:ok, payload, rest} <- extract_payload(remaining, payload_size) do
      {:event, command, <<command::8>> <> payload, rest}
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

  defp get_payload_size(command, payload_sizes) do
    case payload_sizes[command] do
      nil ->
        {:error, :unknown_command}

      size ->
        {:ok, size}
    end
  end
end
