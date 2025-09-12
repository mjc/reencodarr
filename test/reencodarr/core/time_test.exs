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
end
