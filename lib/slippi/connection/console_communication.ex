defmodule Slippi.ConsoleCommunication do
  require Logger

  @moduledoc """
  Handles communication protocol between the Wii and the Elixir app.
  Based on the Slippi JS implementation.
  """

  @message_types %{
    handshake: 1,
    replay: 2,
    keep_alive: 3
  }

  defmodule Message do
    @type t :: %__MODULE__{
            type: integer(),
            payload: binary()
          }
    defstruct [:type, :payload]
  end

  @doc """
  Generates a handshake message to send to the console.
  """
  @spec generate_handshake(binary(), integer(), boolean()) :: binary()
  def generate_handshake(cursor, client_token, is_realtime \\ false) do
    # Convert client_token to 4-byte binary
    client_token_bin = <<client_token::big-unsigned-32>>

    message = %{
      type: @message_types.handshake,
      payload: %{
        cursor: cursor,
        clientToken: :binary.bin_to_list(client_token_bin),
        isRealtime: is_realtime
      }
    }

    {:ok, encoded} = UBJSON.encode(message)
    # Add message length prefix (4 bytes)
    <<byte_size(encoded)::big-unsigned-32, encoded::binary>>
  end

  @doc """
  Determines the initial communication state based on the first message.
  Returns :legacy or :normal
  """
  def get_initial_comm_state(data) when byte_size(data) < 13, do: :legacy

  def get_initial_comm_state(data) do
    opening_bytes = <<0x7B, 0x69, 0x04, 0x74, 0x79, 0x70, 0x65, 0x55, 0x01>>
    data_start = binary_part(data, 4, 9)

    if data_start == opening_bytes, do: :normal, else: :legacy
  end

  @doc """
  Processes received data and returns a list of decoded messages.
  Returns a tuple containing the list of messages and any remaining buffer data.

  - data: the new data to process
  - buffer: the current buffer of data
  """
  @spec process_received_data(binary(), binary()) :: {[Message.t()], binary()}
  def process_received_data(data, buffer \\ <<>>) do
    buffer = <<buffer::binary, data::binary>>
    process_messages(buffer, [])
  end

  # Processes messages from a buffer.
  # Returns the accumulated messages and the remaining buffer.
  @spec process_messages(binary(), [Message.t()]) :: {[Message.t()], binary()}
  defp process_messages(buffer, messages) when byte_size(buffer) < 4 do
    # If the buffer is less than 4 bytes, we don't have a complete message
    {Enum.reverse(messages), buffer}
  end

  # Handles incomplete messages where the buffer is smaller than the indicated message size.
  # Returns accumulated messages and keeps the incomplete message in the buffer.
  @spec process_messages(binary(), [Message.t()]) :: {[Message.t()], binary()}
  defp process_messages(<<msg_size::big-unsigned-32, rest::binary>> = buffer, messages)
       when byte_size(rest) < msg_size + 4 do
    {Enum.reverse(messages), buffer}
  end

  # Main message processing function that handles complete messages.
  # Decodes each message using UBJSON format and recursively processes the remaining buffer.
  #
  # Parameters:
  #   * buffer - Binary data containing at least one complete message
  #   * messages - List of already processed messages
  #
  # The function:
  # 1. Extracts message size from first 4 bytes
  # 2. Takes that many bytes as message data
  # 3. Attempts to decode as UBJSON
  # 4. On success, adds decoded message to accumulator
  # 5. Recursively processes remaining buffer
  @spec process_messages(binary(), [Message.t()]) :: {[Message.t()], binary()}
  defp process_messages(<<msg_size::big-unsigned-32, rest::binary>> = _buffer, messages) do
    <<msg_data::binary-size(msg_size), new_rest::binary>> = rest

    case UBJSON.decode(msg_data) do
      {:ok, decoded} ->
        message = %Message{
          type: decoded["type"],
          payload: decoded["payload"]
        }

        process_messages(new_rest, [message | messages])

      {:error, _reason} ->
        process_messages(new_rest, messages)
    end
  end
end
