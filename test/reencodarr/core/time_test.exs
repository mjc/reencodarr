defmodule Reencodarr.Core.TimeTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Core.Time

  describe "relative_time_with_timezone/2" do
    test "handles nil datetime" do
      assert Time.relative_time_with_timezone(nil, "UTC") == "N/A"
      assert Time.relative_time_with_timezone(nil, "America/New_York") == "N/A"
    end

    test "handles empty timezone" do
      now = NaiveDateTime.utc_now()
      result = Time.relative_time_with_timezone(now, "")
      assert is_binary(result)
      assert result != "N/A"
    end

    test "handles nil timezone" do
      now = NaiveDateTime.utc_now()
      result = Time.relative_time_with_timezone(now, nil)
      assert is_binary(result)
      assert result != "N/A"
    end

    test "handles valid timezone" do
      now = NaiveDateTime.utc_now()
      result = Time.relative_time_with_timezone(now, "America/New_York")
      assert is_binary(result)
      assert result != "N/A"
    end

    test "returns relative time string" do
      # Test with a datetime that's exactly now
      now = NaiveDateTime.utc_now()
      result = Time.relative_time_with_timezone(now, "UTC")
      assert is_binary(result)
      assert result != "N/A"
      # Could be "just now", "X seconds ago", "X minutes ago", etc.
      assert String.contains?(result, "now") or String.contains?(result, "ago") or
               String.contains?(result, "second")
    end
  end

  describe "to_seconds/2" do
    test "converts seconds (unchanged)" do
      assert Time.to_seconds(5, "seconds") == 5
      assert Time.to_seconds(5, "second") == 5
    end

    test "converts minutes to seconds" do
      assert Time.to_seconds(5, "minutes") == 300
      assert Time.to_seconds(1, "minute") == 60
    end

    test "converts hours to seconds" do
      assert Time.to_seconds(2, "hours") == 7200
      assert Time.to_seconds(1, "hour") == 3600
    end

    test "converts days to seconds" do
      assert Time.to_seconds(1, "days") == 86_400
      assert Time.to_seconds(1, "day") == 86_400
    end

    test "converts weeks to seconds" do
      assert Time.to_seconds(1, "weeks") == 604_800
      assert Time.to_seconds(2, "week") == 1_209_600
    end

    test "converts months to seconds" do
      assert Time.to_seconds(1, "months") == 2_629_746
      assert Time.to_seconds(1, "month") == 2_629_746
    end

    test "converts years to seconds" do
      assert Time.to_seconds(1, "years") == 31_556_952
      assert Time.to_seconds(1, "year") == 31_556_952
    end

    test "falls back to trunc for unknown unit" do
      assert Time.to_seconds(3, "unknown") == 3
      assert Time.to_seconds(7, "fortnights") == 7
    end

    test "truncates float input" do
      assert Time.to_seconds(1.5, "minutes") == 90
      assert Time.to_seconds(2.9, "seconds") == 2
    end

    test "is case-insensitive for unit" do
      assert Time.to_seconds(5, "MINUTES") == 300
      assert Time.to_seconds(2, "Hours") == 7200
    end
  end

  describe "convert_time_to_duration/1" do
    test "converts captures with all fields present" do
      result =
        Time.convert_time_to_duration(%{"hours" => "1", "minutes" => "30", "seconds" => "15"})

      assert result == %{hours: 1, minutes: 30, seconds: 15}
    end

    test "defaults missing keys to zero" do
      result = Time.convert_time_to_duration(%{"hours" => "2"})
      assert result == %{hours: 2, minutes: 0, seconds: 0}
    end

    test "handles empty map with all zeros" do
      result = Time.convert_time_to_duration(%{})
      assert result == %{hours: 0, minutes: 0, seconds: 0}
    end

    test "handles minutes and seconds without hours" do
      result = Time.convert_time_to_duration(%{"minutes" => "5", "seconds" => "30"})
      assert result == %{hours: 0, minutes: 5, seconds: 30}
    end
  end

  describe "relative_time/1" do
    test "returns N/A for nil" do
      assert Time.relative_time(nil) == "N/A"
    end

    test "returns N/A for unsupported types" do
      assert Time.relative_time(:some_atom) == "N/A"
      assert Time.relative_time(12_345) == "N/A"
    end

    test "returns seconds ago for recent DateTime" do
      recent = DateTime.add(DateTime.utc_now(), -5, :second)
      result = Time.relative_time(recent)
      assert String.ends_with?(result, "seconds ago")
    end

    test "returns minutes ago for DateTime ~2 minutes ago" do
      past = DateTime.add(DateTime.utc_now(), -120, :second)
      result = Time.relative_time(past)
      assert String.ends_with?(result, "minutes ago")
    end

    test "returns hours ago for DateTime ~2 hours ago" do
      past = DateTime.add(DateTime.utc_now(), -7_200, :second)
      result = Time.relative_time(past)
      assert String.ends_with?(result, "hours ago")
    end

    test "handles NaiveDateTime by delegating to DateTime" do
      naive = NaiveDateTime.add(NaiveDateTime.utc_now(), -10, :second)
      result = Time.relative_time(naive)
      assert is_binary(result)
      assert result != "N/A"
    end

    test "handles valid ISO8601 binary string" do
      past = DateTime.add(DateTime.utc_now(), -30, :second)
      iso = DateTime.to_iso8601(past)
      result = Time.relative_time(iso)
      assert is_binary(result)
      assert result != "N/A"
    end

    test "returns N/A for invalid binary string" do
      assert Time.relative_time("not-a-date") == "N/A"
      assert Time.relative_time("") == "N/A"
    end
  end

  describe "format_duration/1" do
    test "returns N/A for nil" do
      assert Time.format_duration(nil) == "N/A"
    end

    test "returns N/A for non-numeric input" do
      assert Time.format_duration(:bad) == "N/A"
      assert Time.format_duration("30s") == "N/A"
    end

    test "returns 0s for zero" do
      assert Time.format_duration(0) == "0s"
    end

    test "formats seconds only" do
      assert Time.format_duration(30) == "30s"
      assert Time.format_duration(59) == "59s"
    end

    test "formats minutes and seconds" do
      assert Time.format_duration(90) == "1m 30s"
      assert Time.format_duration(125) == "2m 5s"
    end

    test "formats hours, minutes, and seconds" do
      assert Time.format_duration(3661) == "1h 1m 1s"
      assert Time.format_duration(7200) == "2h 0m 0s"
    end

    test "truncates float input" do
      assert Time.format_duration(45.9) == "45s"
    end
  end

  describe "format_eta/2" do
    test "returns singular unit when eta is 1" do
      assert Time.format_eta(1, "hour") == "1 hour"
      assert Time.format_eta(1, "minute") == "1 minute"
    end

    test "appends s for plural unit not already ending in s" do
      assert Time.format_eta(2, "hour") == "2 hours"
      assert Time.format_eta(5, "minute") == "5 minutes"
    end

    test "does not double-append s when unit already ends in s" do
      assert Time.format_eta(3, "minutes") == "3 minutes"
      assert Time.format_eta(2, "hours") == "2 hours"
    end
  end

  describe "format_eta/1" do
    test "returns binary string unchanged (passthrough)" do
      assert Time.format_eta("5 minutes") == "5 minutes"
      assert Time.format_eta("1h 30m 0s") == "1h 30m 0s"
    end

    test "delegates number to format_duration" do
      assert Time.format_eta(90) == "1m 30s"
      assert Time.format_eta(0) == "0s"
      assert Time.format_eta(3661) == "1h 1m 1s"
    end

    test "returns N/A for unrecognized input" do
      assert Time.format_eta(nil) == "N/A"
      assert Time.format_eta(:bad) == "N/A"
    end
  end
end
