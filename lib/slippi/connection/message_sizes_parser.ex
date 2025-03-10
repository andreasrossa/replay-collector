defmodule Slippi.Connection.MessageSizesParser do
  @moduledoc """
  Handles parsing of binary data from Slippi connections.
  """
  require Logger

  @doc """
  Processes message size information received from the console.
  """
  @spec process_message_sizes(binary(), non_neg_integer()) :: %{byte() => non_neg_integer()}
  def process_message_sizes(payload, payload_len) do
    process_message_size_chunk(payload, payload_len - 1, %{})
  end

  # Exit condition
  @spec process_message_size_chunk(binary(), non_neg_integer(), map()) :: map()
  def process_message_size_chunk(_binary, 0, acc), do: acc

  def process_message_size_chunk(_binary, remaining, acc) when remaining < 0 do
    Logger.error("Remaining bytes is less than 0: #{remaining}\nacc: #{inspect(acc)}")
  end

  # Process a chunk of the message size information
  def process_message_size_chunk(
        <<command::unsigned-integer-size(8), payload_size::unsigned-integer-size(16),
          rest::binary>>,
        remaining,
        acc
      ) do
    process_message_size_chunk(
      rest,
      # 3 bytes = command (1 byte) + payload size (2 bytes)
      remaining - 3,
      Map.put(acc, command, payload_size)
    )
  end
end
