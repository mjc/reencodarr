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
        Map.new(paths, &{&1, false})
      end)

      paths = ["/tmp/1.mkv", "/tmp/2.mkv", "/tmp/3.mkv"]

      result = MediaInfoOptimizer.execute_optimized_mediainfo_command(paths)
      assert {:ok, %{}} = result
    end

    test "preserves full-scan fields through the optimized path" do
      :meck.expect(ConcurrencyManager, :get_optimal_mediainfo_batch_size, fn -> 4 end)

      path = Path.expand("../../../fixtures/mediainfo_no_statistics_dtshd.mka", __DIR__)

      assert {:ok, %{^path => mediainfo}} =
               MediaInfoOptimizer.execute_optimized_mediainfo_command([path])

      audio =
        mediainfo
        |> get_in(["media", "track"])
        |> Enum.find(&(Map.get(&1, "@type") == "Audio"))

      assert audio["Format_Commercial_IfAny"] == "DTS-HD Master Audio"
      assert String.to_integer(audio["BitRate"]) > 0
      assert String.to_integer(audio["StreamSize"]) > 0
    end
  end
end
