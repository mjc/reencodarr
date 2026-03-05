defmodule Reencodarr.Analyzer.Optimization.BulkFileCheckerTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Analyzer.Optimization.BulkFileChecker

  setup do
    tmp_dir = System.tmp_dir!()
    prefix = "bulk_file_checker_test_#{System.unique_integer([:positive])}_"
    {:ok, tmp_dir: tmp_dir, prefix: prefix}
  end

  describe "check_files_exist/1" do
    test "returns empty map for empty list" do
      # Early-return clause avoids max_concurrency: 0 crash
      assert BulkFileChecker.check_files_exist([]) == %{}
    end

    test "returns true for an existing file", %{tmp_dir: tmp_dir, prefix: prefix} do
      path = Path.join(tmp_dir, "#{prefix}existing.mkv")
      File.write!(path, "data")
      on_exit(fn -> File.rm(path) end)

      result = BulkFileChecker.check_files_exist([path])
      assert result == %{path => true}
    end

    test "returns false for a non-existing file" do
      path = "/no/such/path/nonexistent_#{System.unique_integer([:positive])}.mkv"
      result = BulkFileChecker.check_files_exist([path])
      assert result == %{path => false}
    end

    test "handles mixed existing and non-existing files", %{tmp_dir: tmp_dir, prefix: prefix} do
      existing = Path.join(tmp_dir, "#{prefix}exists.mkv")
      missing = "/no/such/path/missing_#{System.unique_integer([:positive])}.mkv"
      File.write!(existing, "data")
      on_exit(fn -> File.rm(existing) end)

      result = BulkFileChecker.check_files_exist([existing, missing])
      assert result[existing] == true
      assert result[missing] == false
    end

    test "handles a batch of multiple existing files", %{tmp_dir: tmp_dir, prefix: prefix} do
      paths =
        Enum.map(1..5, fn i ->
          path = Path.join(tmp_dir, "#{prefix}file#{i}.mkv")
          File.write!(path, "content #{i}")
          path
        end)

      on_exit(fn -> Enum.each(paths, &File.rm/1) end)

      result = BulkFileChecker.check_files_exist(paths)
      assert map_size(result) == 5
      assert Enum.all?(paths, fn path -> result[path] == true end)
    end

    test "handles a batch of multiple non-existing files" do
      paths =
        Enum.map(1..4, fn i ->
          "/no/such/path/batch_missing_#{System.unique_integer([:positive])}_#{i}.mkv"
        end)

      result = BulkFileChecker.check_files_exist(paths)
      assert map_size(result) == 4
      assert Enum.all?(paths, fn path -> result[path] == false end)
    end

    test "returns map with all input paths as keys", %{tmp_dir: tmp_dir, prefix: prefix} do
      existing = Path.join(tmp_dir, "#{prefix}key_test.mkv")
      missing = "/tmp/no_such_#{System.unique_integer([:positive])}.mkv"
      File.write!(existing, "data")
      on_exit(fn -> File.rm(existing) end)

      paths = [existing, missing]
      result = BulkFileChecker.check_files_exist(paths)

      assert MapSet.new(Map.keys(result)) == MapSet.new(paths)
    end
  end
end
