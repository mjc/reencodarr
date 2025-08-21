defmodule Reencodarr.FormattersTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Formatters

  describe "format_file_size/1 (binary prefixes)" do
    test "formats bytes with binary prefixes correctly" do
      assert Formatters.format_file_size(0) == "0 B"
      assert Formatters.format_file_size(512) == "512 B"
      assert Formatters.format_file_size(1024) == "1.0 KiB"
      assert Formatters.format_file_size(1_048_576) == "1.0 MiB"
      assert Formatters.format_file_size(1_073_741_824) == "1.0 GiB"
      assert Formatters.format_file_size(1_099_511_627_776) == "1.0 TiB"
    end

    test "handles fractional values with proper precision" do
      assert Formatters.format_file_size(1536) == "1.5 KiB"
      assert Formatters.format_file_size(1_610_612_736) == "1.5 GiB"
      assert Formatters.format_file_size(2_684_354_560) == "2.5 GiB"
    end

    test "handles edge cases and invalid input" do
      assert Formatters.format_file_size(nil) == "N/A"
      assert Formatters.format_file_size(-1024) == "N/A"
      assert Formatters.format_file_size("invalid") == "N/A"
      assert Formatters.format_file_size(%{}) == "N/A"
    end
  end

  describe "format_file_size_decimal/1 (decimal prefixes)" do
    test "formats bytes with decimal prefixes correctly" do
      assert Formatters.format_file_size_decimal(0) == "0 B"
      assert Formatters.format_file_size_decimal(1000) == "1.0 KB"
      assert Formatters.format_file_size_decimal(1_000_000) == "1.0 MB"
      assert Formatters.format_file_size_decimal(1_000_000_000) == "1.0 GB"
      assert Formatters.format_file_size_decimal(1_000_000_000_000) == "1.0 TB"
    end

    test "handles fractional values with proper precision" do
      assert Formatters.format_file_size_decimal(1500) == "1.5 KB"
      assert Formatters.format_file_size_decimal(2_500_000_000) == "2.5 GB"
    end

    test "handles edge cases and invalid input" do
      assert Formatters.format_file_size_decimal(nil) == "N/A"
      assert Formatters.format_file_size_decimal(-1000) == "N/A"
      assert Formatters.format_file_size_decimal("invalid") == "N/A"
    end
  end

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

    test "handles zero and invalid values" do
      assert Formatters.format_file_size_gib(0) == 0.0
      assert Formatters.format_file_size_gib("invalid") == 0.0
      assert Formatters.format_file_size_gib(%{}) == 0.0
    end

    test "rounds to 2 decimal places" do
      # Test precision
      assert Formatters.format_file_size_gib(1_073_741_825) == 1.0
      assert Formatters.format_file_size_gib(1_610_612_736) == 1.5
      assert Formatters.format_file_size_gib(1_234_567_890) == 1.15
    end
  end

  describe "format_savings_gb/1" do
    test "formats gigabytes correctly" do
      assert Formatters.format_savings_gb(0.2) == "200 MiB"
      assert Formatters.format_savings_gb(1.0) == "1.0 GiB"
      assert Formatters.format_savings_gb(1.5) == "1.5 GiB"
      assert Formatters.format_savings_gb(2.75) == "2.75 GiB"
      assert Formatters.format_savings_gb(999.99) == "999.99 GiB"
    end

    test "formats terabytes correctly" do
      assert Formatters.format_savings_gb(1000.0) == "1.0 TiB"
      assert Formatters.format_savings_gb(1500.0) == "1.5 TiB"
      assert Formatters.format_savings_gb(2750.5) == "2.8 TiB"
    end

    test "formats megabytes correctly" do
      assert Formatters.format_savings_gb(0.001) == "1 MiB"
      assert Formatters.format_savings_gb(0.1) == "100 MiB"
      assert Formatters.format_savings_gb(0.512) == "512 MiB"
      assert Formatters.format_savings_gb(0.999) == "999 MiB"
    end

    test "formats very small values" do
      assert Formatters.format_savings_gb(0.0001) == "< 1 MiB"
      assert Formatters.format_savings_gb(0.0005) == "< 1 MiB"
    end

    test "handles invalid values" do
      assert Formatters.format_savings_gb(nil) == "N/A"
      assert Formatters.format_savings_gb(0) == "N/A"
      assert Formatters.format_savings_gb(-1) == "N/A"
      assert Formatters.format_savings_gb("invalid") == "N/A"
    end

    test "formats realistic video savings scenarios" do
      # 4K video scenarios
      assert Formatters.format_savings_gb(5.2) == "5.2 GiB"
      assert Formatters.format_savings_gb(15.7) == "15.7 GiB"

      # 1080p video scenarios
      assert Formatters.format_savings_gb(1.2) == "1.2 GiB"
      assert Formatters.format_savings_gb(2.8) == "2.8 GiB"

      # TV episode scenarios
      assert Formatters.format_savings_gb(0.5) == "500 MiB"
      assert Formatters.format_savings_gb(0.25) == "250 MiB"

      # Collection scenarios
      assert Formatters.format_savings_gb(1250.0) == "1.3 TiB"
      assert Formatters.format_savings_gb(3400.5) == "3.4 TiB"
    end
  end

  describe "format_filename/1" do
    test "extracts episode info from TV show filenames" do
      assert Formatters.format_filename("/path/to/Sample Show Alpha - S01E01.mkv") ==
               "Sample Show Alpha - S01E01"

      assert Formatters.format_filename("Test Series Beta - S02E03.mp4") ==
               "Test Series Beta - S02E03"

      assert Formatters.format_filename("Test Series Beta - S02E05 - Something.mp4") ==
               "Test Series Beta - S02E05"
    end

    test "handles movie names without series info" do
      assert Formatters.format_filename("/path/to/test_movie.mp4") == "test_movie.mp4"
      assert Formatters.format_filename("SampleMovie.mkv") == "SampleMovie.mkv"
      assert Formatters.format_filename("/path/to/movie.mp4") == "movie.mp4"
      assert Formatters.format_filename("Some Movie (2023).mkv") == "Some Movie (2023).mkv"
    end

    test "handles edge cases" do
      assert Formatters.format_filename(nil) == "N/A"
      assert Formatters.format_filename(123) == "N/A"
      assert Formatters.format_filename("") == ""
    end

    test "handles paths correctly" do
      assert Formatters.format_filename("/long/path/to/Demo Show Gamma - S01E01.mkv") ==
               "Demo Show Gamma - S01E01"
    end
  end

  # Test backward compatibility functions
  describe "backward compatibility" do
    test "format_size_with_unit/1 delegates to format_file_size/1" do
      assert Formatters.format_size_with_unit(1024) == "1.0 KiB"
      assert Formatters.format_size_with_unit(nil) == "N/A"
    end

    test "format_size_gb/1 works correctly" do
      assert Formatters.format_size_gb(1_073_741_824) == "1.0 GiB"
      assert Formatters.format_size_gb(nil) == "N/A"
    end
  end

  describe "format_duration/1" do
    test "formats duration with hours, minutes, and seconds" do
      assert Formatters.format_duration(3661) == "1h 1m 1s"
      assert Formatters.format_duration(125) == "2m 5s"
      assert Formatters.format_duration(45) == "45s"
    end

    test "handles zero and short durations" do
      assert Formatters.format_duration(0) == "N/A"
      assert Formatters.format_duration(1) == "1s"
      assert Formatters.format_duration(60) == "1m"
      assert Formatters.format_duration(3600) == "1h"
    end

    test "handles edge cases" do
      assert Formatters.format_duration(nil) == "N/A"
      assert Formatters.format_duration("invalid") == "invalid"
    end
  end

  describe "normalize_string/1" do
    test "trims whitespace and converts to lowercase" do
      assert Formatters.normalize_string("  Hello World  ") == "hello world"
      assert Formatters.normalize_string("UPPERCASE") == "uppercase"
      assert Formatters.normalize_string("MixedCase") == "mixedcase"
    end

    test "handles edge cases" do
      assert Formatters.normalize_string("") == ""
      assert Formatters.normalize_string("   ") == ""
      assert Formatters.normalize_string(nil) == ""
      assert Formatters.normalize_string(123) == ""
    end
  end
end
