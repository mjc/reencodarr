defmodule Reencodarr.FormatHelpersTest do
  use ExUnit.Case, async: true

  alias Reencodarr.FormatHelpers

  describe "format_file_size_gib/1" do
    test "converts bytes to GiB correctly" do
      # 1 GiB = 1,073,741,824 bytes
      assert FormatHelpers.format_file_size_gib(1_073_741_824) == 1.0
      assert FormatHelpers.format_file_size_gib(2_147_483_648) == 2.0
      assert FormatHelpers.format_file_size_gib(536_870_912) == 0.5
    end

    test "handles nil input" do
      assert FormatHelpers.format_file_size_gib(nil) == 0.0
    end

    test "handles zero and negative values" do
      assert FormatHelpers.format_file_size_gib(0) == 0.0
    end

    test "handles invalid input" do
      assert FormatHelpers.format_file_size_gib("invalid") == 0.0
      assert FormatHelpers.format_file_size_gib(%{}) == 0.0
    end

    test "rounds to 2 decimal places" do
      # Test precision
      assert FormatHelpers.format_file_size_gib(1_073_741_825) == 1.0
      assert FormatHelpers.format_file_size_gib(1_610_612_736) == 1.5
    end
  end

  describe "format_filename/1" do
    test "extracts series and episode info" do
      assert FormatHelpers.format_filename("/path/to/Breaking Bad - S01E01.mkv") ==
               "Breaking Bad - S01E01"

      assert FormatHelpers.format_filename("The Wire - S02E03.mp4") == "The Wire - S02E03"
    end

    test "handles movie names without series info" do
      assert FormatHelpers.format_filename("/path/to/movie.mp4") == "movie.mp4"
      assert FormatHelpers.format_filename("SomeMovie.mkv") == "SomeMovie.mkv"
    end

    test "handles invalid input" do
      assert FormatHelpers.format_filename(nil) == "N/A"
      assert FormatHelpers.format_filename(123) == "N/A"
    end

    test "handles paths correctly" do
      assert FormatHelpers.format_filename("/long/path/to/Show - S01E01.mkv") == "Show - S01E01"
    end
  end
end
