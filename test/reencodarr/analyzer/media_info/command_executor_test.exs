defmodule Reencodarr.Analyzer.MediaInfo.CommandExecutorTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Analyzer.MediaInfo.CommandExecutor
  alias Reencodarr.Analyzer.Optimization.BulkFileChecker

  setup do
    :meck.unload()
    :ok
  end

  describe "execute_batch_mediainfo/1" do
    test "returns empty map for empty input" do
      assert {:ok, %{}} = CommandExecutor.execute_batch_mediainfo([])
    end

    test "returns empty map when all files are filtered out as missing" do
      :meck.new(BulkFileChecker, [:passthrough])

      :meck.expect(BulkFileChecker, :check_files_exist, fn _paths ->
        [{"/tmp/missing1.mkv", false}, {"/tmp/missing2.mkv", false}]
      end)

      assert {:ok, %{}} =
               CommandExecutor.execute_batch_mediainfo([
                 "/tmp/missing1.mkv",
                 "/tmp/missing2.mkv"
               ])
    end

    test "filters out non-existent files before processing" do
      :meck.new(BulkFileChecker, [:passthrough])

      :meck.expect(BulkFileChecker, :check_files_exist, fn _paths ->
        [
          {"/tmp/exists1.mkv", true},
          {"/tmp/missing.mkv", false},
          {"/tmp/exists2.mkv", true}
        ]
      end)

      # All non-existent files filtered, so empty result expected
      assert {:ok, %{}} =
               CommandExecutor.execute_batch_mediainfo([
                 "/tmp/exists1.mkv",
                 "/tmp/missing.mkv",
                 "/tmp/exists2.mkv"
               ])
    end
  end

  describe "execute_single_mediainfo/1" do
    test "returns explicit error for missing file" do
      path = "/tmp/definitely_missing_#{System.unique_integer([:positive])}.mkv"

      assert {:error, "file does not exist: " <> ^path} =
               CommandExecutor.execute_single_mediainfo(path)
    end

    test "returns error for invalid/empty path" do
      assert {:error, _} = CommandExecutor.execute_single_mediainfo("")
    end

    test "rejects non-existent paths early" do
      paths = [
        "/tmp/test_#{System.unique_integer([:positive])}.mkv",
        "/nonexistent/path/video.mkv",
        "~/relative/path.mkv"
      ]

      Enum.each(paths, fn path ->
        assert {:error, "file does not exist: " <> _} =
                 CommandExecutor.execute_single_mediainfo(path)
      end)
    end
  end
end
