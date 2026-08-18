defmodule Reencodarr.Analyzer.MediaInfo.CommandExecutorTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Analyzer.MediaInfo.CommandExecutor
  alias Reencodarr.Analyzer.Optimization.BulkFileChecker

  setup do
    :meck.unload()
    :ok
  end

  describe "arguments/1" do
    test "always requests complete fields and a full file scan exactly once" do
      args = CommandExecutor.arguments(["/media/one.mkv", "/media/two.mkv"])

      assert Enum.count(args, &(&1 == "--Full")) == 1
      assert Enum.count(args, &(&1 == "--ParseSpeed=1.0")) == 1
      assert Enum.take(args, -2) == ["/media/one.mkv", "/media/two.mkv"]
    end
  end

  describe "command_batches/2" do
    test "batches only files at or below 5 GiB" do
      small_paths = for name <- ~w(one two three), do: temp_file(name, 1_024)

      large_paths =
        for name <- ~w(large huge), do: temp_file(name, 5 * 1024 * 1024 * 1024 + 1)

      batches = CommandExecutor.command_batches(small_paths ++ large_paths, 2)

      assert Enum.sort(batches) ==
               Enum.sort([
                 Enum.take(small_paths, 2),
                 Enum.drop(small_paths, 2),
                 [Enum.at(large_paths, 0)],
                 [Enum.at(large_paths, 1)]
               ])

      on_exit(fn -> Enum.each(small_paths ++ large_paths, &File.rm!/1) end)
    end
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

    test "full-scans every file in a real multi-codec batch" do
      paths = [
        fixture_path("mediainfo_no_statistics_eac3.mka"),
        fixture_path("mediainfo_no_statistics_dtshd.mka")
      ]

      assert {:ok, results} = CommandExecutor.execute_batch_mediainfo(paths)

      for path <- paths do
        audio = audio_track(Map.fetch!(results, path))
        assert String.to_integer(audio["BitRate"]) > 0
        assert String.to_integer(audio["StreamSize"]) > 0
      end
    end
  end

  describe "execute_single_mediainfo/1" do
    test "full-scans representative codecs without bitrate statistics" do
      fixtures = [
        {"mediainfo_no_statistics.mkv", "AAC", nil},
        {"mediainfo_no_statistics_eac3.mka", "E-AC-3", "Dolby Digital Plus"},
        {"mediainfo_no_statistics_dtshd.mka", "DTS", "DTS-HD Master Audio"}
      ]

      for {name, format, commercial} <- fixtures do
        path = fixture_path(name)

        assert {:ok, %{^path => mediainfo}} = CommandExecutor.execute_single_mediainfo(path)

        audio = audio_track(mediainfo)

        assert audio["Format"] == format
        assert audio["Format_Commercial_IfAny"] == commercial
        assert String.to_integer(audio["BitRate"]) > 0
        assert String.to_integer(audio["StreamSize"]) > 0
      end
    end

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

  defp fixture_path(name), do: Path.expand("../../../fixtures/#{name}", __DIR__)

  defp temp_file(name, size) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.mkv")
    {:ok, file} = :file.open(path, [:write, :binary])
    {:ok, _position} = :file.position(file, size - 1)
    :ok = :file.write(file, <<0>>)
    :ok = :file.close(file)
    path
  end

  defp audio_track(mediainfo) do
    mediainfo
    |> get_in(["media", "track"])
    |> Enum.find(&(Map.get(&1, "@type") == "Audio"))
  end
end
