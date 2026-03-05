defmodule Reencodarr.Analyzer.Core.ConcurrencyManagerTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Analyzer.Core.ConcurrencyManager

  # In the test environment, PerformanceMonitor is not running,
  # so storage tier defaults to :unknown and conservative limits apply.

  describe "get_video_processing_concurrency/0" do
    test "returns a positive integer" do
      result = ConcurrencyManager.get_video_processing_concurrency()
      assert is_integer(result)
      assert result >= 1
    end

    test "returns at least the minimum concurrency (2)" do
      result = ConcurrencyManager.get_video_processing_concurrency()
      assert result >= 2
    end

    test "returns at most the standard max concurrency (16) when storage tier is unknown" do
      # In test env, PerformanceMonitor is not running → tier = :unknown → max = 16
      result = ConcurrencyManager.get_video_processing_concurrency()
      assert result <= 16
    end
  end

  describe "get_mediainfo_concurrency/0" do
    test "returns a positive integer" do
      result = ConcurrencyManager.get_mediainfo_concurrency()
      assert is_integer(result)
      assert result >= 1
    end

    test "returns at least 2" do
      result = ConcurrencyManager.get_mediainfo_concurrency()
      assert result >= 2
    end
  end

  describe "get_processing_timeout/0" do
    test "returns a positive integer representing milliseconds" do
      result = ConcurrencyManager.get_processing_timeout()
      assert is_integer(result)
      assert result > 0
    end

    test "returns at least 2 minutes in milliseconds" do
      # Base timeout is 2 minutes = 120_000ms; load may reduce below 1.5x that
      two_minutes_ms = :timer.minutes(2)
      result = ConcurrencyManager.get_processing_timeout()
      # Even at 1.5x load reduction, floor is 2 minutes
      assert result >= two_minutes_ms
    end
  end

  describe "get_optimal_mediainfo_batch_size/0" do
    test "returns a positive integer" do
      result = ConcurrencyManager.get_optimal_mediainfo_batch_size()
      assert is_integer(result)
      assert result >= 1
    end

    test "returns a conservative batch size when storage tier is unknown (test env)" do
      # In test env tier = :unknown → batch size = 8
      result = ConcurrencyManager.get_optimal_mediainfo_batch_size()
      assert result == 8
    end
  end
end
