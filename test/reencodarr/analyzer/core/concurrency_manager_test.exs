defmodule Reencodarr.Analyzer.Core.ConcurrencyManagerTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Analyzer.Core.ConcurrencyManager

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

    test "returns at most 16" do
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
      two_minutes_ms = :timer.minutes(2)
      result = ConcurrencyManager.get_processing_timeout()
      assert result >= two_minutes_ms
    end
  end

  describe "get_optimal_mediainfo_batch_size/0" do
    test "returns 8" do
      assert ConcurrencyManager.get_optimal_mediainfo_batch_size() == 8
    end
  end
end
