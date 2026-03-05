defmodule Reencodarr.Analyzer.Core.FileOperationsTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Analyzer.Core.FileOperations

  setup do
    tmp_dir = System.tmp_dir!()
    prefix = "file_ops_test_#{System.unique_integer([:positive])}_"
    {:ok, tmp_dir: tmp_dir, prefix: prefix}
  end

  describe "check_files_exist/1" do
    test "returns empty map for empty list" do
      # Delegates to BulkFileChecker which early-returns for empty list
      assert FileOperations.check_files_exist([]) == %{}
    end

    test "returns true for an existing file", %{tmp_dir: tmp_dir, prefix: prefix} do
      path = Path.join(tmp_dir, "#{prefix}exists.mkv")
      File.write!(path, "hello")
      on_exit(fn -> File.rm(path) end)

      result = FileOperations.check_files_exist([path])
      assert result[path] == true
    end

    test "returns false for a non-existing file" do
      path = "/tmp/no_such_file_#{System.unique_integer([:positive])}.mkv"
      result = FileOperations.check_files_exist([path])
      assert result[path] == false
    end
  end

  describe "file_exists?/1" do
    test "returns true for an existing file", %{tmp_dir: tmp_dir, prefix: prefix} do
      path = Path.join(tmp_dir, "#{prefix}file_exists.mkv")
      File.write!(path, "data")
      on_exit(fn -> File.rm(path) end)

      assert FileOperations.file_exists?(path) == true
    end

    test "returns false for a non-existing file" do
      path = "/tmp/no_such_#{System.unique_integer([:positive])}.mkv"
      assert FileOperations.file_exists?(path) == false
    end
  end

  describe "get_file_stats/1" do
    test "returns ok with stats map for existing file", %{tmp_dir: tmp_dir, prefix: prefix} do
      path = Path.join(tmp_dir, "#{prefix}stats.mkv")
      File.write!(path, "some content")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, stats} = FileOperations.get_file_stats(path)
      assert stats.exists == true
      assert stats.size > 0
    end

    test "returns ok with exists false for missing file" do
      path = "/tmp/missing_stat_#{System.unique_integer([:positive])}.mkv"
      assert {:ok, %{exists: false}} = FileOperations.get_file_stats(path)
    end
  end

  describe "filter_existing_files/1" do
    test "returns only existing files from a mixed list", %{tmp_dir: tmp_dir, prefix: prefix} do
      existing = Path.join(tmp_dir, "#{prefix}keep.mkv")
      missing = "/tmp/gone_#{System.unique_integer([:positive])}.mkv"
      File.write!(existing, "data")
      on_exit(fn -> File.rm(existing) end)

      result = FileOperations.filter_existing_files([existing, missing])
      assert existing in result
      refute missing in result
    end

    test "returns empty list when no files exist" do
      paths = [
        "/tmp/gone1_#{System.unique_integer([:positive])}.mkv",
        "/tmp/gone2_#{System.unique_integer([:positive])}.mkv"
      ]

      assert FileOperations.filter_existing_files(paths) == []
    end

    test "returns all files when all exist", %{tmp_dir: tmp_dir, prefix: prefix} do
      paths =
        Enum.map(1..3, fn i ->
          path = Path.join(tmp_dir, "#{prefix}allexist#{i}.mkv")
          File.write!(path, "content #{i}")
          path
        end)

      on_exit(fn -> Enum.each(paths, &File.rm/1) end)

      result = FileOperations.filter_existing_files(paths)
      assert length(result) == 3
    end

    test "returns empty list for empty input" do
      # BulkFileChecker early-return for empty list avoids max_concurrency: 0
      assert FileOperations.filter_existing_files([]) == []
    end
  end

  describe "validate_file_for_processing/1" do
    test "returns ok with stats for a valid file", %{tmp_dir: tmp_dir, prefix: prefix} do
      path = Path.join(tmp_dir, "#{prefix}valid.mkv")
      File.write!(path, "valid content")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, stats} = FileOperations.validate_file_for_processing(path)
      assert stats.exists == true
    end

    test "returns error for non-existing file" do
      path = "/tmp/nonexistent_validate_#{System.unique_integer([:positive])}.mkv"
      assert {:error, message} = FileOperations.validate_file_for_processing(path)
      assert message =~ "does not exist"
    end

    test "returns error for empty file", %{tmp_dir: tmp_dir, prefix: prefix} do
      path = Path.join(tmp_dir, "#{prefix}empty.mkv")
      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      assert {:error, message} = FileOperations.validate_file_for_processing(path)
      assert message =~ "empty"
    end
  end

  describe "validate_files_for_processing/1" do
    test "returns a map with ok and error results", %{tmp_dir: tmp_dir, prefix: prefix} do
      valid_path = Path.join(tmp_dir, "#{prefix}valid_batch.mkv")
      missing_path = "/tmp/gone_batch_#{System.unique_integer([:positive])}.mkv"
      File.write!(valid_path, "content")
      on_exit(fn -> File.rm(valid_path) end)

      result = FileOperations.validate_files_for_processing([valid_path, missing_path])

      assert {:ok, _} = result[valid_path]
      assert {:error, _} = result[missing_path]
    end

    test "returns empty map for empty input" do
      assert FileOperations.validate_files_for_processing([]) == %{}
    end
  end
end
