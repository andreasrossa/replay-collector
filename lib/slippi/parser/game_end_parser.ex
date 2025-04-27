defmodule Slippi.Parser.GameEndParser do
  import Slippi.Parser.ParsingUtilities

  @type game_end_payload :: %{
          game_end_type: non_neg_integer(),
          lras: non_neg_integer()
        }

  @moduledoc """
  Parses the game end message.
  """

  @spec parse_game_end(binary()) :: {:ok, game_end_payload()} | {:error, any()}
  def parse_game_end(payload) do
    try do
      game_end_payload = %{
        game_end_type: read_uint_8(payload, 0x1),
        lras: read_uint_8(payload, 0x2)
      }

      {:ok, game_end_payload}
    rescue
      error ->
        {:error, error}
    end
  end
end
