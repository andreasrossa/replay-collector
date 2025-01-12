defmodule UBJSONTest do
  use ExUnit.Case
  doctest UBJSON

  import Bitwise

  test "encodes and decodes basic types" do
    test_cases = [
      nil,
      :noop,
      true,
      false,
      42,
      -42,
      3.14159,
      "hello",
      [1, 2, 3],
      %{"key" => "value"},
      %{"nested" => %{"array" => [1, 2, 3]}}
    ]

    for value <- test_cases do
      assert {:ok, encoded} = UBJSON.encode(value)
      assert {:ok, ^value} = UBJSON.decode(encoded)
    end
  end

  test "handles large numbers" do
    large_num = 12_345_678_901_234_567_890
    assert {:ok, encoded} = UBJSON.encode(large_num)
    assert {:ok, ^large_num} = UBJSON.decode(encoded)
  end

  test "can encode slippi file" do
    # Read the slippi file
    {:ok, slp_data} = File.read("test/fixtures/game.slp")

    # Convert binary to list of bytes
    bytes = for <<byte::8 <- slp_data>>, do: byte

    # Encode to UBJSON
    {:ok, encoded} = UBJSON.encode(bytes)

    # Print some information about the encoding
    IO.puts("\nSlippi file analysis:")
    IO.puts("Original size: #{byte_size(slp_data)} bytes")
    IO.puts("UBJSON size: #{byte_size(encoded)} bytes")

    # Write the encoded data to files
    File.write!("encoded_slippi.ubj", encoded)

    # Create a hex dump for better readability
    hex_dump =
      encoded
      |> :binary.bin_to_list()
      |> Enum.chunk_every(16)
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        # Format: "OFFSET: XX XX XX XX XX XX XX XX  XX XX XX XX XX XX XX XX  ASCII"
        hex =
          chunk
          |> Enum.map(&String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
          |> Enum.chunk_every(8)
          |> Enum.map(&Enum.join(&1, " "))
          |> Enum.join("  ")

        ascii =
          chunk
          |> Enum.map(fn byte ->
            case byte do
              x when x >= 32 and x <= 126 -> <<x>>
              _ -> "."
            end
          end)
          |> Enum.join()

        offset = String.pad_leading(Integer.to_string(index * 16, 16), 8, "0")
        "#{offset}: #{String.pad_trailing(hex, 48)} #{ascii}"
      end)
      |> Enum.join("\n")

    File.write!("encoded_slippi.hex", hex_dump)

    # Verify we can decode it back
    {:ok, decoded} = UBJSON.decode(encoded)
    assert decoded == bytes

    IO.puts("\nWrote encoded data to 'encoded_slippi.ubj'")
    IO.puts("Wrote hex dump to 'encoded_slippi.hex'")
  end

  test "can extract slippi metadata" do
    # Melee Stage IDs
    stages = %{
      2 => "Fountain of Dreams",
      3 => "Pokémon Stadium",
      4 => "Princess Peach's Castle",
      5 => "Kongo Jungle",
      6 => "Brinstar",
      7 => "Corneria",
      8 => "Yoshi's Story",
      9 => "Onett",
      10 => "Mute City",
      11 => "Rainbow Cruise",
      12 => "Jungle Japes",
      13 => "Great Bay",
      14 => "Hyrule Temple",
      15 => "Brinstar Depths",
      16 => "Yoshi's Island",
      17 => "Green Greens",
      18 => "Fourside",
      19 => "Mushroom Kingdom I",
      20 => "Mushroom Kingdom II",
      22 => "Venom",
      23 => "Poké Floats",
      24 => "Big Blue",
      25 => "Icicle Mountain",
      26 => "Icetop",
      27 => "Flat Zone",
      28 => "Dream Land N64",
      29 => "Yoshi's Island N64",
      30 => "Kongo Jungle N64",
      31 => "Battlefield",
      32 => "Final Destination"
    }

    # Read the slippi file
    {:ok, slp_data} = File.read("test/fixtures/game.slp")

    # The file starts with raw game data
    # First find the game start event (0x36)
    case :binary.match(slp_data, <<0x36>>) do
      :nomatch ->
        IO.puts("No game start event found")

      {pos, _} ->
        <<_pre::binary-size(pos), event_code, version_len, version::binary-size(version_len),
          game_start_data::binary>> = slp_data

        IO.puts("\nSlippi Metadata:")
        IO.puts("Event Code: 0x#{Integer.to_string(event_code, 16)}")
        IO.puts("Version length: #{version_len}")
        IO.puts("Version (hex): #{inspect(version, base: :hex)}")

        # Parse game start data
        case game_start_data do
          <<
            random_seed::64,
            pal::8,
            frozen_ps::8,
            minor_scene::8,
            major_scene::8,
            game_mode::8,
            is_teams::8,
            item_spawn::8,
            nickname_len::8,
            nickname::binary-size(nickname_len),
            # Game Info Block (1 byte)
            game_info_block::8,
            # Player data
            # Fixed size for first player
            player1_data::binary-size(25),
            # Stage ID comes right after first player
            stage_id::big-16,
            _rest::binary
          >> ->
            # Count how many players are present
            player_count =
              0..3
              |> Enum.count(fn i -> (game_info_block &&& 1 <<< i) != 0 end)

            IO.puts("\nGame Start Data:")
            IO.puts("Random Seed: 0x#{Integer.to_string(random_seed, 16)}")
            IO.puts("PAL: #{pal == 1}")
            IO.puts("Frozen PS: #{frozen_ps == 1}")
            IO.puts("Scene: #{major_scene}.#{minor_scene}")
            IO.puts("Game Mode: #{game_mode}")
            IO.puts("Teams: #{is_teams == 1}")
            IO.puts("Item Spawn: #{item_spawn}")
            IO.puts("Nickname length: #{nickname_len}")
            IO.puts("Console Nickname (hex): #{inspect(nickname, base: :hex)}")
            IO.puts("\nGame Info:")
            IO.puts("Number of players: #{player_count}")
            IO.puts("Player 1 data (hex): #{inspect(player1_data, base: :hex)}")
            IO.puts("Stage ID: #{stage_id} (#{Map.get(stages, stage_id, "Unknown Stage")})")

          _ ->
            IO.puts("Failed to parse game start data")

            IO.puts(
              "First 32 bytes: #{inspect(binary_part(game_start_data, 0, min(32, byte_size(game_start_data))), base: :hex)}"
            )
        end
    end
  end
end
