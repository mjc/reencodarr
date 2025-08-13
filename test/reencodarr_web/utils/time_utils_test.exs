defmodule ReencodarrWeb.Utils.TimeUtilsTest do
  use ExUnit.Case, async: true

  alias ReencodarrWeb.Utils.TimeUtils

  describe "relative_time_with_timezone/2" do
    test "handles nil datetime" do
      assert TimeUtils.relative_time_with_timezone(nil, "UTC") == "N/A"
      assert TimeUtils.relative_time_with_timezone(nil, "America/New_York") == "N/A"
    end

    test "handles empty timezone" do
      now = NaiveDateTime.utc_now()
      result = TimeUtils.relative_time_with_timezone(now, "")
      assert is_binary(result)
      assert result != "N/A"
    end

    test "handles nil timezone" do
      now = NaiveDateTime.utc_now()
      result = TimeUtils.relative_time_with_timezone(now, nil)
      assert is_binary(result)
      assert result != "N/A"
    end

    test "handles valid timezone" do
      now = NaiveDateTime.utc_now()
      result = TimeUtils.relative_time_with_timezone(now, "America/New_York")
      assert is_binary(result)
      assert result != "N/A"
    end

    test "returns relative time string" do
      # Test with a datetime that's exactly now
      now = NaiveDateTime.utc_now()
      result = TimeUtils.relative_time_with_timezone(now, "UTC")
      assert String.contains?(result, "ago") or String.contains?(result, "second")
    end
  end
end
