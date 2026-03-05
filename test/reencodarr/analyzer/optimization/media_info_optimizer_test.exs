defmodule Reencodarr.Analyzer.MediaInfoOptimizerTest do
  use Reencodarr.UnitCase, async: false

  alias Reencodarr.Analyzer.{
    Core.ConcurrencyManager,
    MediaInfoOptimizer,
    Optimization.BulkFileChecker
  }

  describe "execute_optimized_mediainfo_command/1" do
    setup do
      :meck.new(BulkFileChecker, [:passthrough])
      :meck.new(ConcurrencyManager, [:passthrough])

      on_exit(fn ->
        :meck.unload()
      end)

      :ok
    end

    test "handles empty list gracefully" do
      :meck.expect(ConcurrencyManager, :get_optimal_mediainfo_batch_size, fn ->
        4
      end)

      assert {:ok, %{}} = MediaInfoOptimizer.execute_optimized_mediainfo_command([])
    end

    test "respects batch size limit from concurrency manager" do
      :meck.expect(ConcurrencyManager, :get_optimal_mediainfo_batch_size, fn ->
        2
      end)

      :meck.expect(BulkFileChecker, :check_files_exist, fn paths ->
        Enum.reduce(paths, %{}, fn path, acc ->
          Map.put(acc, path, false)
        end)
      end)

      paths = ["/tmp/1.mkv", "/tmp/2.mkv", "/tmp/3.mkv"]

      result = MediaInfoOptimizer.execute_optimized_mediainfo_command(paths)
      assert {:ok, %{}} = result
    end
  end
end
