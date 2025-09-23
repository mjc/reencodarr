defmodule Reencodarr.FormattersTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Formatters

  describe "file_size/1" do
    test "formats bytes with binary prefixes correctly" do
      assert Formatters.file_size(0) == "0 B"
      assert Formatters.file_size(512) == "512 B"
      assert Formatters.file_size(1024) == "1.0 KiB"
      assert Formatters.file_size(1_048_576) == "1.0 MiB"
      assert Formatters.file_size(1_073_741_824) == "1.0 GiB"
      assert Formatters.file_size(1_099_511_627_776) == "1.0 TiB"
      # Test very large values
      assert Formatters.file_size(5_497_558_138_880) == "5.0 TiB"
    end

    test "handles fractional values with proper precision" do
      assert Formatters.file_size(1536) == "1.5 KiB"
      assert Formatters.file_size(1_610_612_736) == "1.5 GiB"
      assert Formatters.file_size(2_684_354_560) == "2.5 GiB"
    end

    test "handles edge cases and invalid input" do
      assert Formatters.file_size(nil) == "N/A"
      assert Formatters.file_size(-1024) == "N/A"
      assert Formatters.file_size("invalid") == "N/A"
      assert Formatters.file_size(%{}) == "N/A"
      assert Formatters.file_size(1.5) == "N/A"
    end
  end

  describe "file_size_gib/1" do
    test "converts bytes to GiB correctly" do
      assert Formatters.file_size_gib(1_073_741_824) == 1.0
      assert Formatters.file_size_gib(2_147_483_648) == 2.0
      assert Formatters.file_size_gib(1_610_612_736) == 1.5
      assert Formatters.file_size_gib(536_870_912) == 0.5
    end

    test "rounds to 2 decimal places" do
      assert Formatters.file_size_gib(1_073_741_825) == 1.0
      assert Formatters.file_size_gib(1_234_567_890) == 1.15
    end

    test "handles invalid input" do
      assert Formatters.file_size_gib(nil) == 0.0
      assert Formatters.file_size_gib(0) == 0.0
      assert Formatters.file_size_gib(-1024) == 0.0
      assert Formatters.file_size_gib("invalid") == 0.0
      assert Formatters.file_size_gib(%{}) == 0.0
    end
  end

  describe "savings_bytes/1" do
    test "formats positive byte values" do
      assert Formatters.savings_bytes(1_073_741_824) == "1.0 GiB"
      assert Formatters.savings_bytes(2_147_483_648) == "2.0 GiB"
      assert Formatters.savings_bytes(1024) == "1.0 KiB"
    end

    test "handles invalid input" do
      assert Formatters.savings_bytes(nil) == "N/A"
      assert Formatters.savings_bytes(0) == "N/A"
      assert Formatters.savings_bytes(-1) == "N/A"
      assert Formatters.savings_bytes("invalid") == "N/A"
    end
  end

  describe "count/1" do
    test "formats counts with K/M/B suffixes" do
      assert Formatters.count(500) == "500"
      assert Formatters.count(1000) == "1.0K"
      assert Formatters.count(1500) == "1.5K"
      assert Formatters.count(1_000_000) == "1.0M"
      assert Formatters.count(2_500_000) == "2.5M"
      assert Formatters.count(1_000_000_000) == "1.0B"
      assert Formatters.count(2_500_000_000) == "2.5B"
    end

    test "handles edge cases" do
      assert Formatters.count(0) == "0"
      assert Formatters.count(999) == "999"
      assert Formatters.count(1001) == "1.0K"
      assert Formatters.count(999_999) == "1000.0K"
      assert Formatters.count(999_999_999) == "1.0e3M"
    end

    test "handles non-integer input" do
      assert Formatters.count(nil) == ""
      assert Formatters.count("500") == "500"
      assert Formatters.count(3.14) == "3.14"
      # Maps cause String.Chars protocol errors, so we can't test this
    end
  end

  describe "bitrate_mbps/1" do
    test "formats bitrate in Mbps" do
      assert Formatters.bitrate_mbps(1_000_000) == "1.0 Mbps"
      assert Formatters.bitrate_mbps(2_500_000) == "2.5 Mbps"
      assert Formatters.bitrate_mbps(10_000_000) == "10.0 Mbps"
    end

    test "handles invalid input" do
      assert Formatters.bitrate_mbps(nil) == "N/A"
      assert Formatters.bitrate_mbps(0) == "N/A"
      assert Formatters.bitrate_mbps(-1000) == "N/A"
      assert Formatters.bitrate_mbps("invalid") == "N/A"
    end
  end

  describe "bitrate/1" do
    test "formats bitrate with appropriate units" do
      assert Formatters.bitrate(500) == "500 bps"
      assert Formatters.bitrate(1000) == "1.0 Kbps"
      assert Formatters.bitrate(1500) == "1.5 Kbps"
      assert Formatters.bitrate(1_000_000) == "1.0 Mbps"
      assert Formatters.bitrate(2_500_000) == "2.5 Mbps"
    end

    test "handles edge cases" do
      assert Formatters.bitrate(0) == "0 bps"
      assert Formatters.bitrate(999) == "999 bps"
      assert Formatters.bitrate(1001) == "1.0 Kbps"
      assert Formatters.bitrate(-1000) == "-1000 bps"
      assert Formatters.bitrate(-1_000_000) == "-1000000 bps"
    end

    test "handles invalid input" do
      assert Formatters.bitrate(nil) == "Unknown"
      assert Formatters.bitrate("invalid") == "Unknown"
      assert Formatters.bitrate(3.14) == "Unknown"
    end
  end

  describe "fps/1" do
    test "formats FPS values" do
      assert Formatters.fps(30) == "30 fps"
      assert Formatters.fps(60) == "60 fps"
      assert Formatters.fps(29.97) == "30.0 fps"
      assert Formatters.fps(23.976) == "24.0 fps"
    end

    test "handles integer vs float display" do
      assert Formatters.fps(30.0) == "30 fps"
      assert Formatters.fps(30.5) == "30.5 fps"
      assert Formatters.fps(0) == "0 fps"
      assert Formatters.fps(0.0) == "0 fps"
    end

    test "handles invalid input" do
      assert Formatters.fps(nil) == ""
      assert Formatters.fps("30") == "30"
      # Lists cause String.Chars protocol issues
    end
  end

  describe "crf/1" do
    test "formats CRF values" do
      assert Formatters.crf(23) == "23"
      assert Formatters.crf(18.5) == "18.5"
      assert Formatters.crf("20") == "20"
      assert Formatters.crf(0) == "0"
    end

    test "handles invalid input" do
      assert Formatters.crf(nil) == ""
      # Lists cause String.Chars protocol issues
    end
  end

  describe "vmaf_score/1" do
    test "formats VMAF scores with one decimal place" do
      assert Formatters.vmaf_score(95.7) == "95.7"
      assert Formatters.vmaf_score(88.123) == "88.1"
      # Use float instead of integer
      assert Formatters.vmaf_score(100.0) == "100.0"
      assert Formatters.vmaf_score(99.99) == "100.0"
      # Use float instead of integer
      assert Formatters.vmaf_score(0.0) == "0.0"
      assert Formatters.vmaf_score(0.0) == "0.0"
    end

    test "handles invalid input" do
      assert Formatters.vmaf_score(nil) == ""
      assert Formatters.vmaf_score("95") == "95"
      # Lists cause String.Chars protocol issues
    end
  end

  describe "codec_info/2" do
    test "formats codec information from lists" do
      assert Formatters.codec_info(["h264"], ["aac"]) == "h264/aac"
      assert Formatters.codec_info(["av1", "h264"], ["ac3", "aac"]) == "av1/ac3"
      assert Formatters.codec_info(["hevc"], ["dts"]) == "hevc/dts"
    end

    test "handles empty lists" do
      assert Formatters.codec_info([], []) == "Unknown/Unknown"
      assert Formatters.codec_info(["h264"], []) == "h264/Unknown"
      assert Formatters.codec_info([], ["aac"]) == "Unknown/aac"
    end

    test "handles invalid input" do
      assert Formatters.codec_info(nil, nil) == "Unknown"
      assert Formatters.codec_info("h264", "aac") == "Unknown"
      assert Formatters.codec_info(%{}, %{}) == "Unknown"
    end
  end

  describe "duration/1" do
    test "formats duration with hours, minutes, seconds" do
      assert Formatters.duration(45) == "45s"
      assert Formatters.duration(90) == "1m 30s"
      assert Formatters.duration(3600) == "1h 0m 0s"
      assert Formatters.duration(3661) == "1h 1m 1s"
      assert Formatters.duration(7323) == "2h 2m 3s"
    end

    test "handles edge cases" do
      assert Formatters.duration(1) == "1s"
      assert Formatters.duration(60) == "1m 0s"
      assert Formatters.duration(61) == "1m 1s"
    end

    test "handles float inputs" do
      assert Formatters.duration(90.5) == "1m 30s"
      assert Formatters.duration(3661.9) == "1h 1m 1s"
    end

    test "handles invalid input" do
      assert Formatters.duration(nil) == "N/A"
      assert Formatters.duration(0) == "0s"
      assert Formatters.duration(-60) == "N/A"
      assert Formatters.duration("invalid") == "N/A"
    end
  end

  describe "eta/1" do
    test "passes through binary strings" do
      assert Formatters.eta("5 minutes") == "5 minutes"
      assert Formatters.eta("") == ""
      assert Formatters.eta("N/A") == "N/A"
    end

    test "delegates numeric values to duration/1" do
      assert Formatters.eta(120) == "2m 0s"
      assert Formatters.eta(3661) == "1h 1m 1s"
      assert Formatters.eta(45.5) == "45s"
      assert Formatters.eta(0) == "0s"
    end

    test "handles invalid input" do
      assert Formatters.eta(nil) == "N/A"
      assert Formatters.eta(%{}) == "N/A"
      assert Formatters.eta([120]) == "N/A"
    end
  end

  describe "relative_time/1" do
    test "formats DateTime relative times" do
      now = DateTime.utc_now()

      past_30_sec = DateTime.add(now, -30, :second)
      result = Formatters.relative_time(past_30_sec)
      # Allow for small timing variations (29-31 seconds)
      assert result =~ ~r/^(29|30|31) seconds ago$/

      past_5_min = DateTime.add(now, -300, :second)
      result = Formatters.relative_time(past_5_min)
      assert result =~ ~r/^[45] minutes ago$/ or result == "5 minutes ago"

      past_2_hours = DateTime.add(now, -7200, :second)
      assert Formatters.relative_time(past_2_hours) == "2 hours ago"

      past_3_days = DateTime.add(now, -259_200, :second)
      assert Formatters.relative_time(past_3_days) == "3 days ago"

      # Test months (> 30 days) - allow for small timing variations
      # ~90 days (7,776,000 seconds)
      past_3_months = DateTime.add(now, -7_776_000, :second)
      result = Formatters.relative_time(past_3_months)
      assert result =~ ~r/^[23] months ago$/ or result == "3 months ago"
    end

    test "handles NaiveDateTime by converting to UTC" do
      naive_dt = ~N[2023-01-01 12:00:00]
      result = Formatters.relative_time(naive_dt)
      assert String.contains?(result, "ago")
    end

    test "parses ISO8601 strings" do
      iso_string = "2023-01-01T12:00:00Z"
      result = Formatters.relative_time(iso_string)
      assert String.contains?(result, "ago")
    end

    test "handles invalid input" do
      assert Formatters.relative_time(nil) == "N/A"
      assert Formatters.relative_time("invalid-date") == "N/A"
      assert Formatters.relative_time(123) == "N/A"
    end
  end

  describe "filename/1" do
    test "extracts episode info from TV show filenames" do
      assert Formatters.filename("Sample Show - S01E01.mkv") == "Sample Show - S01E01"
      assert Formatters.filename("Test Series - S02E03.mp4") == "Test Series - S02E03"
      assert Formatters.filename("/path/to/Demo Show - S01E01.mkv") == "Demo Show - S01E01"
    end

    test "handles movie names without series pattern" do
      assert Formatters.filename("movie.mp4") == "movie.mp4"
      assert Formatters.filename("Some Movie (2023).mkv") == "Some Movie (2023).mkv"
      assert Formatters.filename("/path/to/test_movie.mp4") == "test_movie.mp4"
    end

    test "handles edge cases" do
      assert Formatters.filename("") == ""
      assert Formatters.filename("file") == "file"
      assert Formatters.filename("file.") == "file."
    end

    test "handles invalid input" do
      assert Formatters.filename(nil) == "N/A"
      assert Formatters.filename(123) == "N/A"
      assert Formatters.filename(%{}) == "N/A"
    end
  end

  describe "progress_field/3" do
    test "gets field from progress map" do
      progress = %{percent: 50, fps: 30, eta: 120}
      assert Formatters.progress_field(progress, :percent, 0) == 50
      assert Formatters.progress_field(progress, :fps, 0) == 30
      assert Formatters.progress_field(progress, :eta, 0) == 120
    end

    test "returns default for missing fields" do
      progress = %{percent: 50}
      assert Formatters.progress_field(progress, :missing, "default") == "default"
      assert Formatters.progress_field(progress, :fps, 0) == 0
      assert Formatters.progress_field(progress, :eta, nil) == nil
    end

    test "handles :none progress state" do
      assert Formatters.progress_field(:none, :percent, 0) == 0
      assert Formatters.progress_field(:none, :any_field, "default") == "default"
    end

    test "handles invalid progress values" do
      assert Formatters.progress_field(nil, :percent, "fallback") == "fallback"
      assert Formatters.progress_field("invalid", :percent, 99) == 99
      assert Formatters.progress_field(123, :percent, "default") == "default"
    end
  end

  describe "value/1" do
    test "formats various value types" do
      assert Formatters.value("hello") == "hello"
      assert Formatters.value(123) == "123"
      assert Formatters.value(3.14) == "3.14"
      assert Formatters.value(:atom) == "atom"
      assert Formatters.value(true) == "true"
      assert Formatters.value(false) == "false"
      # Lists and maps cause String.Chars protocol issues, so we don't test those
    end

    test "handles nil input" do
      assert Formatters.value(nil) == "N/A"
    end
  end

  describe "size_to_bytes/2" do
    test "converts string size with units to bytes" do
      assert Formatters.size_to_bytes("1", "B") == 1
      assert Formatters.size_to_bytes("1", "KB") == 1024
      assert Formatters.size_to_bytes("1", "MB") == 1_048_576
      assert Formatters.size_to_bytes("1", "GB") == 1_073_741_824
      assert Formatters.size_to_bytes("1.5", "GB") == 1_610_612_736
      assert Formatters.size_to_bytes("2", "TB") == 2_199_023_255_552
    end

    test "converts numeric size with units to bytes" do
      assert Formatters.size_to_bytes(1, "B") == 1
      assert Formatters.size_to_bytes(1, "KB") == 1024
      assert Formatters.size_to_bytes(1, "MB") == 1_048_576
      assert Formatters.size_to_bytes(1.5, "GB") == 1_610_612_736
    end

    test "handles case insensitive units" do
      assert Formatters.size_to_bytes("1", "gb") == 1_073_741_824
      assert Formatters.size_to_bytes("1", "Mb") == 1_048_576
      assert Formatters.size_to_bytes("1", "KB") == 1024
    end

    test "handles invalid input" do
      assert Formatters.size_to_bytes("invalid", "GB") == nil
      assert Formatters.size_to_bytes("1", "invalid_unit") == nil
      assert Formatters.size_to_bytes(nil, "GB") == nil
      assert Formatters.size_to_bytes("1", nil) == nil
    end
  end

  describe "get_unit_multiplier/1" do
    test "returns correct multipliers for valid units" do
      assert Formatters.get_unit_multiplier("B") == {:ok, 1}
      assert Formatters.get_unit_multiplier("KB") == {:ok, 1024}
      assert Formatters.get_unit_multiplier("MB") == {:ok, 1_048_576}
      assert Formatters.get_unit_multiplier("GB") == {:ok, 1_073_741_824}
      assert Formatters.get_unit_multiplier("TB") == {:ok, 1_099_511_627_776}
    end

    test "handles case insensitive units" do
      assert Formatters.get_unit_multiplier("b") == {:ok, 1}
      assert Formatters.get_unit_multiplier("kb") == {:ok, 1024}
      assert Formatters.get_unit_multiplier("Mb") == {:ok, 1_048_576}
      assert Formatters.get_unit_multiplier("GB") == {:ok, 1_073_741_824}
    end

    test "returns error for invalid units" do
      assert Formatters.get_unit_multiplier("invalid") == {:error, :unknown_unit}
      assert Formatters.get_unit_multiplier("XB") == {:error, :unknown_unit}
      assert Formatters.get_unit_multiplier("") == {:error, :unknown_unit}
    end
  end

  describe "potential_savings_gib/2" do
    test "calculates potential savings in GiB" do
      # 2 GiB
      original_size = 2_147_483_648
      # 1 GiB
      predicted_size = 1_073_741_824
      assert Formatters.potential_savings_gib(original_size, predicted_size) == 1.0
    end

    test "handles fractional savings" do
      # 1.5 GiB
      original_size = 1_610_612_736
      # 0.5 GiB
      predicted_size = 536_870_912
      assert Formatters.potential_savings_gib(original_size, predicted_size) == 1.0
    end

    test "handles invalid input" do
      assert Formatters.potential_savings_gib(nil, 1000) == "N/A"
      assert Formatters.potential_savings_gib(1000, nil) == "N/A"
      assert Formatters.potential_savings_gib("invalid", 1000) == "N/A"
    end
  end

  describe "savings_percentage/2" do
    test "calculates savings percentage correctly" do
      assert Formatters.savings_percentage(1000, 750) == 25.0
      assert Formatters.savings_percentage(2000, 500) == 75.0
      assert Formatters.savings_percentage(100, 90) == 10.0
    end

    test "handles edge cases" do
      assert Formatters.savings_percentage(1000, 1000) == 0.0
      # Growth, not savings
      assert Formatters.savings_percentage(1000, 1500) == -50.0
    end

    test "handles invalid input" do
      assert Formatters.savings_percentage(nil, 750) == "N/A"
      assert Formatters.savings_percentage(1000, nil) == "N/A"
      assert Formatters.savings_percentage("invalid", 750) == "N/A"
    end
  end

  describe "display_count/1" do
    test "formats counts with K/M suffixes" do
      assert Formatters.display_count(500) == "500"
      assert Formatters.display_count(1500) == "1.5K"
      assert Formatters.display_count(2500) == "2.5K"
      assert Formatters.display_count(1_500_000) == "1.5M"
      assert Formatters.display_count(2_500_000) == "2.5M"
    end

    test "handles edge cases" do
      assert Formatters.display_count(0) == "0"
      assert Formatters.display_count(999) == "999"
      assert Formatters.display_count(1000) == "1.0K"
      assert Formatters.display_count(1_000_000) == "1.0M"
    end

    test "handles invalid input" do
      assert Formatters.display_count(nil) == "N/A"
      assert Formatters.display_count("invalid") == "N/A"
      assert Formatters.display_count(3.14) == "N/A"
    end
  end

  describe "rate/1" do
    test "formats rate values correctly" do
      assert Formatters.rate(5.678) == "5.7"
      assert Formatters.rate(10.0) == "10.0"
      assert Formatters.rate(0.1234) == "0.1"
      assert Formatters.rate(100.999) == "101.0"
    end

    test "handles edge cases" do
      assert Formatters.rate(0.0) == "0.0"
      # Integer 0 will convert to float before being rounded
      assert Formatters.rate(0) == "0.0"
    end

    test "handles invalid input" do
      assert Formatters.rate(nil) == "N/A"
      assert Formatters.rate("invalid") == "N/A"
      assert Formatters.rate(:atom) == "N/A"
    end
  end

  describe "duration_minutes/1" do
    test "converts seconds to minutes" do
      assert Formatters.duration_minutes(60) == "1.0 min"
      assert Formatters.duration_minutes(150) == "2.5 min"
      assert Formatters.duration_minutes(90) == "1.5 min"
      assert Formatters.duration_minutes(3600) == "60.0 min"
    end

    test "handles edge cases" do
      assert Formatters.duration_minutes(0) == "0.0 min"
      assert Formatters.duration_minutes(30) == "0.5 min"
      # Rounds to 0.0
      assert Formatters.duration_minutes(1) == "0.0 min"
    end

    test "handles invalid input" do
      assert Formatters.duration_minutes(nil) == "Unknown"
      assert Formatters.duration_minutes("invalid") == "Unknown"
      assert Formatters.duration_minutes(:atom) == "Unknown"
    end
  end

  describe "size_gb/2" do
    test "converts bytes to GB with default decimal places" do
      # 1 GiB = 1.074 GB
      assert Formatters.size_gb(1_073_741_824) == "1.0 GB"
      # 2 GiB
      assert Formatters.size_gb(2_147_483_648) == "2.0 GB"
      # 1.5 GiB
      assert Formatters.size_gb(1_610_612_736) == "1.5 GB"
    end

    test "converts bytes to GB with specified decimal places" do
      # Note: Float.round may not preserve trailing zeros
      # Elixir Float.round doesn't pad zeros
      assert Formatters.size_gb(1_073_741_824, 2) == "1.0 GB"
      assert Formatters.size_gb(1_234_567_890, 2) == "1.15 GB"
      # Float.round(1.15, 0) = 1.0, not 1
      assert Formatters.size_gb(1_234_567_890, 0) == "1.0 GB"
    end

    test "handles edge cases" do
      assert Formatters.size_gb(0) == "0.0 GB"
      # Very small, rounds to 0.0
      assert Formatters.size_gb(1024) == "0.0 GB"
    end

    test "handles invalid input" do
      assert Formatters.size_gb(nil) == "Unknown"
      assert Formatters.size_gb("invalid") == "Unknown"
      assert Formatters.size_gb(:atom, 2) == "Unknown"
    end
  end

  describe "percentage/2" do
    test "calculates percentages correctly" do
      assert Formatters.percentage(3, 4) == 75.0
      assert Formatters.percentage(1, 2) == 50.0
      assert Formatters.percentage(1, 3) == 33.3
      assert Formatters.percentage(0, 4) == 0.0
    end

    test "handles edge cases" do
      # Division by zero protection
      assert Formatters.percentage(0, 0) == 0.0
      # Division by zero protection
      assert Formatters.percentage(5, 0) == 0.0
      assert Formatters.percentage(4, 4) == 100.0
    end

    test "handles invalid input" do
      assert Formatters.percentage(nil, 4) == 0.0
      assert Formatters.percentage(3, nil) == 0.0
      assert Formatters.percentage("invalid", 4) == 0.0
    end
  end

  describe "resolution/2" do
    test "formats resolution correctly" do
      assert Formatters.resolution(1920, 1080) == "1920x1080"
      assert Formatters.resolution(3840, 2160) == "3840x2160"
      assert Formatters.resolution(1280, 720) == "1280x720"
    end

    test "handles edge cases" do
      assert Formatters.resolution(0, 0) == "0x0"
      assert Formatters.resolution(1, 1) == "1x1"
    end

    test "handles invalid input" do
      assert Formatters.resolution(nil, 1080) == "Unknown"
      assert Formatters.resolution(1920, nil) == "Unknown"
      assert Formatters.resolution("1920", 1080) == "Unknown"
      assert Formatters.resolution(1920, "1080") == "Unknown"
    end
  end

  describe "codec_list/1" do
    test "formats codec lists correctly" do
      assert Formatters.codec_list(["h264", "aac"]) == "h264, aac"
      assert Formatters.codec_list(["av1"]) == "av1"
      # Takes only first 2
      assert Formatters.codec_list(["h264", "aac", "mov"]) == "h264, aac"
    end

    test "handles edge cases" do
      assert Formatters.codec_list([]) == "None"
      assert Formatters.codec_list(["single_codec"]) == "single_codec"
    end

    test "handles invalid input" do
      assert Formatters.codec_list(nil) == "Unknown"
      assert Formatters.codec_list("not_a_list") == "Unknown"
      assert Formatters.codec_list(123) == "Unknown"
    end
  end

  describe "vmaf_score/2" do
    test "formats VMAF scores with specified decimal places" do
      assert Formatters.vmaf_score(95.67890, 2) == "95.68"
      assert Formatters.vmaf_score(95.67890, 1) == "95.7"
      # Float.round(95.67890, 0) = 96.0, not 96
      assert Formatters.vmaf_score(95.67890, 0) == "96.0"
      # Already has decimal
      assert Formatters.vmaf_score(100.0, 2) == "100.0"
    end

    test "handles edge cases" do
      assert Formatters.vmaf_score(0.0, 1) == "0.0"
      assert Formatters.vmaf_score(99.999, 2) == "100.0"
    end

    test "handles invalid input" do
      assert Formatters.vmaf_score("invalid", 2) == "invalid"
      assert Formatters.vmaf_score(nil, 2) == ""
      assert Formatters.vmaf_score(95.67, "invalid") == "95.67"
    end
  end
end
