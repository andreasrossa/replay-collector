defmodule Slippi.Parser.ParsingUtilities do
  import Bitwise, only: [band: 2]
  require Logger

  @moduledoc """
  Utility functions for parsing Slippi messages.
  """

  @doc """
  Decodes a binary string encoded with Shift-JIS, removing null terminators.
  Similar to the iconv.decode + splitting by null in the TypeScript code.
  """

  def decode_shift_jis(binary) do
    try do
      # Convert binary to a list of bytes for processing
      bytes = :binary.bin_to_list(binary)

      # Find the first null terminator or take the whole string
      null_pos = Enum.find_index(bytes, &(&1 == 0))
      relevant_bytes = if null_pos, do: Enum.take(bytes, null_pos), else: bytes

      # Convert back to binary for processing
      data = :binary.list_to_bin(relevant_bytes)

      # Decode using Shift-JIS if Codepagex is available
      # Otherwise return the data as is (you may want to add proper handling)
      case Code.ensure_loaded?(Codepagex) do
        true ->
          case Codepagex.to_string(data, "VENDORS/MICSFT/WINDOWS/CP932") do
            {:ok, string} -> to_halfwidth(string)
          end

        false ->
          # Fallback if Codepagex is not available
          data
      end
    rescue
      error ->
        Logger.debug("Error decoding shift-jis: #{inspect(error)}")
        nil
    end
  end

  @doc """
  Decodes a binary string encoded with UTF-8, removing null terminators.
  """
  def decode_utf8(binary) do
    try do
      bytes = :binary.bin_to_list(binary)
      null_pos = Enum.find_index(bytes, &(&1 == 0))
      relevant_bytes = if null_pos, do: Enum.take(bytes, null_pos), else: bytes
      data = :binary.list_to_bin(relevant_bytes)

      case String.valid?(data) do
        true -> data
        false -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc """
  Converts fullwidth characters to halfwidth when possible.
  This is a simplified version of the toHalfwidth function in the TypeScript code.
  """
  def to_halfwidth(string) do
    # This is a simplified implementation
    # You might want to add more conversions based on your needs
    string
    |> String.replace("！", "!")
    |> String.replace("？", "?")
    |> String.replace("：", ":")
    |> String.replace("；", ";")
    |> String.replace("，", ",")
    |> String.replace("．", ".")
    |> String.replace("　", " ")
  end

  # Utility functions for reading different data types
  @spec read_int_32(binary(), non_neg_integer()) :: integer() | nil
  def read_int_32(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 4),
         <<value::signed-integer-32>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading int32 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding int32 at offset #{offset}")
        nil
    end
  end

  @spec read_uint_16(binary(), non_neg_integer()) :: non_neg_integer() | nil
  def read_uint_16(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 2),
         <<value::unsigned-integer-16>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading uint16 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding uint16 at offset #{offset}")
        nil
    end
  end

  @spec read_uint_8(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer() | nil
  def read_uint_8(payload, offset, bitmask \\ 0xFF) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 1),
         <<value::unsigned-integer-8>> <- binary_data do
      band(value, bitmask)
    else
      {:error, reason} ->
        Logger.error("Error reading uint8 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding uint8 at offset #{offset}")
        nil
    end
  end

  @spec read_uint_32(binary(), non_neg_integer()) :: non_neg_integer() | nil
  def read_uint_32(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 4),
         <<value::unsigned-integer-32>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.debug("Error reading uint32 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.debug("Error decoding uint32 at offset #{offset}")
        nil
    end
  end

  @spec read_int_8(binary(), non_neg_integer()) :: integer() | nil
  def read_int_8(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 1),
         <<value::signed-integer-8>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.debug("Error reading int8 at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.debug("Error decoding int8 at offset #{offset}")
        nil
    end
  end

  @spec read_float(binary(), non_neg_integer()) :: float() | nil
  def read_float(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 4),
         <<value::float-32>> <- binary_data do
      value
    else
      {:error, reason} ->
        Logger.error("Error reading float at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding float at offset #{offset}")
        nil
    end
  end

  @spec read_bool(binary(), non_neg_integer()) :: boolean() | nil
  def read_bool(payload, offset) do
    with {:ok, binary_data} <- safe_binary_part(payload, offset, 1),
         <<value::unsigned-integer-8>> <- binary_data do
      value != 0
    else
      {:error, reason} ->
        Logger.error("Error reading bool at offset #{offset}: #{reason}")
        nil

      _ ->
        Logger.error("Error decoding bool at offset #{offset}")
        nil
    end
  end

  # Helper function to safely extract a binary part
  @spec safe_binary_part(binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, any()}
  def safe_binary_part(binary, start, length) do
    try do
      {:ok, binary_part(binary, start, length)}
    rescue
      error -> {:error, error}
    end
  end
end
