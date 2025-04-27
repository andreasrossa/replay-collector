defmodule Slippi.Parser.PayloadSizesParser do
  require Logger

  @doc """
  Processes payload size information received from the console.
  """
  @spec parse_payload_sizes(binary()) ::
          {:ok, %{byte() => non_neg_integer()}} | {:error, any()}
  def parse_payload_sizes(payload) do
    try do
      parse_payload_size_chunk(payload, byte_size(payload), %{})
    rescue
      reason ->
        {:error, reason}
    end
  end

  # Exit condition
  @spec parse_payload_size_chunk(binary(), non_neg_integer(), map()) ::
          {:ok, %{byte() => non_neg_integer()}} | {:error, atom()}
  def parse_payload_size_chunk(_binary, 0, acc), do: {:ok, acc}

  def parse_payload_size_chunk(_binary, remaining, acc) when remaining < 0 do
    Logger.error("Remaining bytes is less than 0: #{remaining}\nacc: #{inspect(acc)}")
    {:error, :remaining_bytes_less_than_zero}
  end

  # Process a chunk of the payload size information
  def parse_payload_size_chunk(
        <<command::unsigned-integer-size(8), payload_size::unsigned-integer-size(16),
          rest::binary>>,
        remaining,
        acc
      ) do
    parse_payload_size_chunk(
      rest,
      # 3 bytes = command (1 byte) + payload size (2 bytes)
      remaining - 3,
      Map.put(acc, command, payload_size)
    )
  end
end
