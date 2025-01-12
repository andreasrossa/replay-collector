defmodule Slippi.ConsoleCommunication do
  @moduledoc """
  Handles communication protocol between the Wii and the Elixir app.
  Based on the Slippi JS implementation.
  """

  # Communication type markers from the JS implementation
  @type_handshake 1
  @type_replay 2
  @type_keep_alive 3

  defmodule Message do
    @type t :: %__MODULE__{
            type: integer(),
            payload: map()
          }
    defstruct [:type, :payload]
  end

  @doc """
  Generates a handshake message to send to the console.
  """
  def generate_handshake(cursor, client_token, is_realtime \\ false) do
    # Convert client_token to 4-byte binary
    client_token_bin = <<client_token::big-unsigned-32>>

    message = %{
      type: @type_handshake,
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
  Processes received data and returns a list of decoded messages.
  """
  def process_received_data(data, buffer \\ <<>>) do
    buffer = <<buffer::binary, data::binary>>
    process_messages(buffer, [])
  end

  defp process_messages(buffer, messages) when byte_size(buffer) < 4 do
    {Enum.reverse(messages), buffer}
  end

  defp process_messages(buffer, messages) do
    <<msg_size::big-unsigned-32, rest::binary>> = buffer

    if byte_size(rest) < msg_size do
      {Enum.reverse(messages), buffer}
    else
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
end
