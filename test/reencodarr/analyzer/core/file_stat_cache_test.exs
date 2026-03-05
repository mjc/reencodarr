defmodule Reencodarr.Analyzer.Core.FileStatCacheTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Analyzer.Core.FileStatCache

  setup do
    # Clear any cached state before each test
    FileStatCache.clear_cache()
    :ok
  end

  describe "get_file_stats/1 for existing files" do
    test "returns exists: true with mtime and size for a real file" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "fsc_test_#{System.unique_integer([:positive])}.mkv")
      File.write!(path, "hello")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{exists: true, mtime: mtime, size: size}} = FileStatCache.get_file_stats(path)
      assert is_integer(mtime)
      assert size == 5
    end

    test "returns consistent results on repeated calls (cache hit)" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "fsc_test_#{System.unique_integer([:positive])}.mkv")
      File.write!(path, "cached")
      on_exit(fn -> File.rm(path) end)

      result1 = FileStatCache.get_file_stats(path)
      result2 = FileStatCache.get_file_stats(path)
      assert result1 == result2
    end
  end

  describe "get_file_stats/1 for non-existent files" do
    test "returns exists: false for a missing file" do
      path = "/no/such/path/fsc_missing_#{System.unique_integer([:positive])}.mkv"
      assert {:ok, %{exists: false}} = FileStatCache.get_file_stats(path)
    end

    test "returns consistent results on repeated calls for missing file" do
      path = "/no/such/path/fsc_missing2_#{System.unique_integer([:positive])}.mkv"
      result1 = FileStatCache.get_file_stats(path)
      result2 = FileStatCache.get_file_stats(path)
      assert result1 == result2
    end
  end

  describe "file_exists?/1" do
    test "returns true for an existing file" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "fsc_exists_#{System.unique_integer([:positive])}.mkv")
      File.write!(path, "data")
      on_exit(fn -> File.rm(path) end)

      assert FileStatCache.file_exists?(path) == true
    end

    test "returns false for a non-existent file" do
      path = "/no/such/path/fsc_nope_#{System.unique_integer([:positive])}.mkv"
      assert FileStatCache.file_exists?(path) == false
    end
  end

  describe "get_bulk_file_stats/1" do
    test "returns empty map for empty list" do
      result = FileStatCache.get_bulk_file_stats([])
      assert result == %{}
    end

    test "returns correct stats for multiple paths" do
      tmp = System.tmp_dir!()
      existing = Path.join(tmp, "fsc_bulk_exists_#{System.unique_integer([:positive])}.mkv")
      missing = "/no/such/path/fsc_bulk_missing_#{System.unique_integer([:positive])}.mkv"
      File.write!(existing, "bulk")
      on_exit(fn -> File.rm(existing) end)

      result = FileStatCache.get_bulk_file_stats([existing, missing])
      assert {:ok, %{exists: true}} = result[existing]
      assert {:ok, %{exists: false}} = result[missing]
    end

    test "returns a map keyed by path" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "fsc_bulk_key_#{System.unique_integer([:positive])}.mkv")
      File.write!(path, "key")
      on_exit(fn -> File.rm(path) end)

      result = FileStatCache.get_bulk_file_stats([path])
      assert Map.has_key?(result, path)
    end
  end

  describe "invalidate/1 and clear_cache/0" do
    test "invalidate removes a specific path from cache" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "fsc_inv_#{System.unique_integer([:positive])}.mkv")
      File.write!(path, "inv")
      on_exit(fn -> File.rm(path) end)

      # Populate cache
      {:ok, _} = FileStatCache.get_file_stats(path)

      # Invalidate
      assert :ok = FileStatCache.invalidate(path)

      # Re-fetch should still work (cache miss → fresh stat)
      assert {:ok, %{exists: true}} = FileStatCache.get_file_stats(path)
    end

    test "clear_cache/0 returns :ok" do
      assert :ok = FileStatCache.clear_cache()
    end

    test "after clear_cache, stats can still be fetched" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "fsc_clear_#{System.unique_integer([:positive])}.mkv")
      File.write!(path, "clear")
      on_exit(fn -> File.rm(path) end)

      FileStatCache.get_file_stats(path)
      FileStatCache.clear_cache()

      # Should still return the right result after cache is cleared
      assert {:ok, %{exists: true}} = FileStatCache.get_file_stats(path)
    end
  end
end
