defmodule Reencodarr.Analyzer.MediaInfoCacheTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Reencodarr.Analyzer.MediaInfoCache

  setup do
    MediaInfoCache.clear_cache()
    :ok
  end

  describe "get_stats/0" do
    test "returns a map with cache_size key" do
      stats = MediaInfoCache.get_stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :cache_size)
    end

    test "returns max_cache_size of 1000" do
      stats = MediaInfoCache.get_stats()
      assert stats.max_cache_size == 1000
    end

    test "returns cache_utilization as a number" do
      stats = MediaInfoCache.get_stats()
      assert is_number(stats.cache_utilization)
    end

    test "cache_size is 0 after clear" do
      stats = MediaInfoCache.get_stats()
      assert stats.cache_size == 0
    end
  end

  describe "clear_cache/0" do
    test "returns :ok" do
      assert :ok = MediaInfoCache.clear_cache()
    end

    test "can be called multiple times" do
      assert :ok = MediaInfoCache.clear_cache()
      assert :ok = MediaInfoCache.clear_cache()
    end
  end

  describe "invalidate/1" do
    test "returns :ok for any path" do
      assert :ok = MediaInfoCache.invalidate("/no/such/path.mkv")
    end

    test "returns :ok for a path not in cache" do
      path = "/tmp/not_cached_#{System.unique_integer([:positive])}.mkv"
      assert :ok = MediaInfoCache.invalidate(path)
    end
  end

  describe "get_mediainfo/1 for non-existent files" do
    test "returns an error tuple for a non-existent file" do
      path = "/no/such/path/mediainfo_cache_test_#{System.unique_integer([:positive])}.mkv"
      assert {:error, _reason} = MediaInfoCache.get_mediainfo(path)
    end
  end

  describe "get_bulk_mediainfo/1" do
    test "returns empty map for empty list" do
      result = MediaInfoCache.get_bulk_mediainfo([])
      assert result == %{}
    end

    test "returns error for non-existent file" do
      path = "/no/such/path/bulk_cache_test_#{System.unique_integer([:positive])}.mkv"
      result = MediaInfoCache.get_bulk_mediainfo([path])
      assert is_map(result)
      assert {:error, _} = result[path]
    end
  end
end
