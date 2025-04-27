defmodule Collector.Workers.FileHandler.PostProcessor do
  @spec post_process_replay_file(String.t(), Collector.Workers.ReplayProcessor.game_info()) ::
          :ok
  def post_process_replay_file(file_path, metadata) do
    footer =
      build_footer_start(metadata)
      |> add_players_data(metadata.players)
      |> add_footer_end()

    # Write the footer
    File.write!(file_path, footer, [:append, :binary])
  end

  defp build_footer_start(metadata) do
    start_time_str = DateTime.to_iso8601(metadata.start_time |> DateTime.from_unix!(:millisecond))

    <<"U", 8, "metadata{", "U", 7, "startAtSU", byte_size(start_time_str), start_time_str::binary,
      "U", 9, "lastFramel", metadata.last_frame::signed-integer-size(32), "U", 11,
      "consoleNickSU", byte_size(metadata.console_nickname), metadata.console_nickname::binary,
      "U", 7, "players{">>
  end

  defp add_players_data(footer, players) do
    Enum.reduce(players, footer, fn {player_index, player}, acc ->
      acc =
        <<acc::binary, "U", byte_size(<<player_index::unsigned-integer-size(32)>>),
          "#{player_index}{", "U", 10, "characters{">>

      # Add character data
      acc =
        Enum.reduce(player.character_usage, acc, fn {character_id, usage}, chars_acc ->
          <<chars_acc::binary, "U", byte_size(<<character_id::unsigned-integer-size(32)>>),
            "#{character_id}l", usage::unsigned-integer-size(32)>>
        end)

      # Add player names
      <<acc::binary, "}", "U", 5, "names{", "U", 7, "netplaySU", byte_size(player.names.netplay),
        player.names.netplay::binary, "U", 4, "codeSU", byte_size(player.names.code),
        player.names.code::binary, "}}">>
    end)
  end

  defp add_footer_end(footer) do
    <<footer::binary, "}", "U", 8, "playedOnSU", 7, "network", "}}">>
  end
end
