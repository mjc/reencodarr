defmodule Reencodarr.LiveViewHelpersConsolidationTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Formatters
  alias ReencodarrWeb.DashboardLiveHelpers
  alias ReencodarrWeb.Utils.TimeUtils

  describe "Formatters.format_file_size_gib/1" do
    test "converts bytes to GiB correctly" do
      # 1 GiB = 1_073_741_824 bytes
      assert Formatters.format_file_size_gib(1_073_741_824) == 1.0
      assert Formatters.format_file_size_gib(2_147_483_648) == 2.0
      assert Formatters.format_file_size_gib(536_870_912) == 0.5
    end

    test "handles edge cases" do
      assert Formatters.format_file_size_gib(nil) == 0.0
      assert Formatters.format_file_size_gib(0) == 0.0
      assert Formatters.format_file_size_gib("invalid") == 0.0
    end

    test "rounds to 2 decimal places" do
      # 1.5 GiB
      assert Formatters.format_file_size_gib(1_610_612_736) == 1.5
      # Complex fractional
      assert Formatters.format_file_size_gib(1_234_567_890) == 1.15
    end
  end

  describe "Formatters.format_filename/1" do
    test "extracts episode info from TV show filenames" do
      assert Formatters.format_filename("/path/to/Sample Show Alpha - S01E01.mkv") ==
               "Sample Show Alpha - S01E01"

      assert Formatters.format_filename("Test Series Beta - S02E05 - Something.mp4") ==
               "Test Series Beta - S02E05"
    end

    test "handles movies without episode pattern" do
      assert Formatters.format_filename("/path/to/movie.mp4") == "movie.mp4"
      assert Formatters.format_filename("Some Movie (2023).mkv") == "Some Movie (2023).mkv"
    end

    test "handles edge cases" do
      assert Formatters.format_filename(nil) == "N/A"
      assert Formatters.format_filename("") == ""
    end
  end

  describe "TimeUtils.relative_time_with_timezone/2" do
    test "handles nil datetime" do
      assert TimeUtils.relative_time_with_timezone(nil, "UTC") == "N/A"
      assert TimeUtils.relative_time_with_timezone(nil, "America/New_York") == "N/A"
    end

    test "handles timezone conversion" do
      # Create a naive datetime
      naive_dt = ~N[2023-01-01 12:00:00]

      # Should return a relative time string (exact content depends on current time)
      result = TimeUtils.relative_time_with_timezone(naive_dt, "UTC")
      assert is_binary(result)
      assert result != "N/A"
    end

    test "handles empty or invalid timezone" do
      naive_dt = ~N[2023-01-01 12:00:00]

      # Should default to UTC
      result_empty = TimeUtils.relative_time_with_timezone(naive_dt, "")
      result_nil = TimeUtils.relative_time_with_timezone(naive_dt, nil)

      assert is_binary(result_empty)
      assert is_binary(result_nil)
    end
  end

  describe "DashboardLiveHelpers.calculate_stardate/1" do
    test "calculates TNG-style stardate" do
      # Test with a known datetime
      datetime = DateTime.from_naive!(~N[2025-01-01 12:00:00], "Etc/UTC")
      stardate = DashboardLiveHelpers.calculate_stardate(datetime)

      # Should be a float around 75xxx for 2025
      assert is_float(stardate)
      assert stardate > 75_000.0
      assert stardate < 76_000.0
    end

    test "handles edge cases gracefully" do
      # Should not crash on invalid input
      result = DashboardLiveHelpers.calculate_stardate(nil)
      assert is_float(result)

      # Should handle current time
      current_stardate = DashboardLiveHelpers.calculate_stardate(DateTime.utc_now())
      assert is_float(current_stardate)
    end

    test "returns consistent format" do
      datetime = DateTime.from_naive!(~N[2025-08-13 15:30:45], "Etc/UTC")
      stardate = DashboardLiveHelpers.calculate_stardate(datetime)

      # Should be rounded to 1 decimal place
      rounded = Float.round(stardate, 1)
      assert stardate == rounded
    end
  end
end
