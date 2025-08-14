defmodule Reencodarr.FormatHelpersTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Formatters

  describe "format_file_size_gib/1" do
    test "converts bytes to GiB correctly" do
      # 1 GiB = 1,073,741,824 bytes
      assert Formatters.format_file_size_gib(1_073_741_824) == 1.0
      assert Formatters.format_file_size_gib(2_147_483_648) == 2.0
      assert Formatters.format_file_size_gib(536_870_912) == 0.5
    end

    test "handles nil input" do
      assert Formatters.format_file_size_gib(nil) == 0.0
    end

    test "handles zero and negative values" do
      assert Formatters.format_file_size_gib(0) == 0.0
    end

    test "handles invalid input" do
      assert Formatters.format_file_size_gib("invalid") == 0.0
      assert Formatters.format_file_size_gib(%{}) == 0.0
    end

    test "rounds to 2 decimal places" do
      # Test precision
      assert Formatters.format_file_size_gib(1_073_741_825) == 1.0
      assert Formatters.format_file_size_gib(1_610_612_736) == 1.5
    end
  end

  describe "format_filename/1" do
    test "extracts episode info from TV show filenames" do
      assert Formatters.format_filename("/path/to/Sample Show Alpha - S01E01.mkv") ==
               "Sample Show Alpha - S01E01"

      assert Formatters.format_filename("Test Series Beta - S02E03.mp4") ==
               "Test Series Beta - S02E03"
    end

    test "handles movie names without series info" do
      assert Formatters.format_filename("/path/to/test_movie.mp4") == "test_movie.mp4"
      assert Formatters.format_filename("SampleMovie.mkv") == "SampleMovie.mkv"
    end

    test "handles edge cases" do
      assert Formatters.format_filename(nil) == "N/A"
      assert Formatters.format_filename(123) == "N/A"
    end

    test "handles paths correctly" do
      assert Formatters.format_filename("/long/path/to/Demo Show Gamma - S01E01.mkv") ==
               "Demo Show Gamma - S01E01"
    end
  end
end
