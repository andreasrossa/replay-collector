defmodule UBJSON do
  @moduledoc """
  UBJSON encoder and decoder implementation for Elixir.
  Supports all core UBJSON types including binary data representation.
  """

  # Type markers as defined in the spec
  @markers %{
    nil_value: ?Z,
    noop: ?N,
    true: ?T,
    false: ?F,
    int8: ?i,
    uint8: ?U,
    int16: ?I,
    int32: ?l,
    int64: ?L,
    float32: ?d,
    float64: ?D,
    high_precision: ?H,
    char: ?C,
    string: ?S,
    array_start: ?[,
    array_end: ?],
    object_start: ?{,
    object_end: ?},
    type: ?$,
    count: ?#
  }

  @doc """
  Encodes an Elixir term into UBJSON format.
  """
  def encode(term) do
    {:ok, do_encode(term)}
  catch
    :error, reason -> {:error, reason}
  end

  @doc """
  Decodes UBJSON binary data into Elixir terms.
  """
  def decode(binary) when is_binary(binary) do
    try do
      case do_decode(binary) do
        {term, <<>>} -> {:ok, term}
        {_, rest} when byte_size(rest) > 0 -> {:error, :invalid_format}
      end
    catch
      :error, reason -> {:error, reason}
    end
  end

  # Encoding implementations
  defp do_encode(nil), do: <<@markers.nil_value>>
  defp do_encode(:noop), do: <<@markers.noop>>
  defp do_encode(true), do: <<@markers.true>>
  defp do_encode(false), do: <<@markers.false>>

  defp do_encode(num) when is_integer(num) do
    cond do
      num >= -128 and num <= 127 ->
        <<@markers.int8, num::signed-8>>

      num >= 0 and num <= 255 ->
        <<@markers.uint8, num::unsigned-8>>

      num >= -32768 and num <= 32767 ->
        <<@markers.int16, num::signed-big-16>>

      num >= -2_147_483_648 and num <= 2_147_483_647 ->
        <<@markers.int32, num::signed-big-32>>

      num >= -9_223_372_036_854_775_808 and num <= 9_223_372_036_854_775_807 ->
        <<@markers.int64, num::signed-big-64>>

      true ->
        encode_high_precision(num)
    end
  end

  defp do_encode(num) when is_float(num) do
    <<@markers.float64, num::float-big-64>>
  end

  defp do_encode(str) when is_binary(str) do
    size = byte_size(str)
    <<@markers.string, do_encode_int(size)::binary, str::binary>>
  end

  defp do_encode(list) when is_list(list) do
    if Enum.all?(list, &is_integer/1) and Enum.all?(list, &(&1 >= 0 and &1 <= 255)) do
      # Only use optimized format if the list is long enough to benefit from it
      # Regular format: [marker + value_marker + value] per element = 2 bytes per element
      # Optimized format: [start + type + uint8 + count + count_size] + 1 byte per element
      regular_size = length(list) * 2
      optimized_size = 4 + byte_size(do_encode_int(length(list))) + length(list)

      if optimized_size < regular_size do
        encode_binary_data(list)
      else
        encode_array(list)
      end
    else
      encode_array(list)
    end
  end

  defp do_encode(map) when is_map(map), do: encode_object(map)

  # Helper functions for encoding
  defp encode_high_precision(num) do
    str = to_string(num)
    size = byte_size(str)
    <<@markers.high_precision, do_encode_int(size)::binary, str::binary>>
  end

  defp encode_binary_data(list) do
    # Encode as optimized uint8 array
    count = length(list)

    <<@markers.array_start, @markers.type, @markers.uint8, @markers.count,
      do_encode_int(count)::binary, encode_uint8_list(list)::binary>>
  end

  defp encode_uint8_list(list) do
    for n <- list, into: <<>>, do: <<n::unsigned-8>>
  end

  defp encode_array(list) do
    encoded = for item <- list, into: <<>>, do: do_encode(item)
    <<@markers.array_start, encoded::binary, @markers.array_end>>
  end

  defp encode_object(map) do
    encoded =
      for {key, value} <- map, into: <<>> do
        key_bin = to_string(key)
        key_size = byte_size(key_bin)
        <<do_encode_int(key_size)::binary, key_bin::binary, do_encode(value)::binary>>
      end

    <<@markers.object_start, encoded::binary, @markers.object_end>>
  end

  defp do_encode_int(num) when num >= -128 and num <= 127,
    do: <<@markers.int8, num::signed-8>>

  defp do_encode_int(num) when num >= 0 and num <= 255,
    do: <<@markers.uint8, num::unsigned-8>>

  defp do_encode_int(num) when num >= -32768 and num <= 32767,
    do: <<@markers.int16, num::signed-big-16>>

  defp do_encode_int(num) when num >= -2_147_483_648 and num <= 2_147_483_647,
    do: <<@markers.int32, num::signed-big-32>>

  defp do_encode_int(num),
    do: <<@markers.int64, num::signed-big-64>>

  # Decoding implementations
  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.nil_value, do: {nil, rest}
  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.noop, do: {:noop, rest}
  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.true, do: {true, rest}
  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.false, do: {false, rest}

  defp do_decode(<<marker::8, value::signed-8, rest::binary>>) when marker == @markers.int8,
    do: {value, rest}

  defp do_decode(<<marker::8, value::unsigned-8, rest::binary>>) when marker == @markers.uint8,
    do: {value, rest}

  defp do_decode(<<marker::8, value::signed-big-16, rest::binary>>) when marker == @markers.int16,
    do: {value, rest}

  defp do_decode(<<marker::8, value::signed-big-32, rest::binary>>) when marker == @markers.int32,
    do: {value, rest}

  defp do_decode(<<marker::8, value::signed-big-64, rest::binary>>) when marker == @markers.int64,
    do: {value, rest}

  defp do_decode(<<marker::8, value::float-big-32, rest::binary>>)
       when marker == @markers.float32,
       do: {value, rest}

  defp do_decode(<<marker::8, value::float-big-64, rest::binary>>)
       when marker == @markers.float64,
       do: {value, rest}

  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.high_precision do
    {size, rest} = decode_int(rest)
    <<str::binary-size(size), rest::binary>> = rest
    {String.to_integer(str), rest}
  end

  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.string do
    {size, rest} = decode_int(rest)
    <<str::binary-size(size), rest::binary>> = rest
    {str, rest}
  end

  defp do_decode(<<marker1::8, marker2::8, marker3::8, marker4::8, rest::binary>>)
       when marker1 == @markers.array_start and marker2 == @markers.type and
              marker3 == @markers.uint8 and marker4 == @markers.count do
    # Handle optimized uint8 array (binary data)
    {count, rest} = decode_int(rest)
    decode_uint8_array(rest, count)
  end

  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.array_start do
    decode_array(rest, [])
  end

  defp do_decode(<<marker::8, rest::binary>>) when marker == @markers.object_start do
    decode_object(rest, %{})
  end

  # Helper functions for decoding
  defp decode_int(<<marker::8, value::signed-8, rest::binary>>) when marker == @markers.int8,
    do: {value, rest}

  defp decode_int(<<marker::8, value::unsigned-8, rest::binary>>) when marker == @markers.uint8,
    do: {value, rest}

  defp decode_int(<<marker::8, value::signed-big-16, rest::binary>>)
       when marker == @markers.int16,
       do: {value, rest}

  defp decode_int(<<marker::8, value::signed-big-32, rest::binary>>)
       when marker == @markers.int32,
       do: {value, rest}

  defp decode_int(<<marker::8, value::signed-big-64, rest::binary>>)
       when marker == @markers.int64,
       do: {value, rest}

  defp decode_uint8_array(binary, count) do
    <<array::binary-size(count), rest::binary>> = binary
    {for(<<byte::unsigned-8 <- array>>, do: byte), rest}
  end

  defp decode_array(<<marker::8, rest::binary>>, acc) when marker == @markers.array_end do
    {Enum.reverse(acc), rest}
  end

  defp decode_array(binary, acc) do
    {value, rest} = do_decode(binary)
    decode_array(rest, [value | acc])
  end

  defp decode_object(<<marker::8, rest::binary>>, acc) when marker == @markers.object_end do
    {acc, rest}
  end

  defp decode_object(binary, acc) do
    {key_size, rest} = decode_int(binary)
    <<key::binary-size(key_size), rest2::binary>> = rest
    {value, rest3} = do_decode(rest2)
    decode_object(rest3, Map.put(acc, key, value))
  end
end
