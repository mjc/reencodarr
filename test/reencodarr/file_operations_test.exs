defmodule Reencodarr.FileOperationsTest do
  use Reencodarr.DataCase, async: false
  import ExUnit.CaptureLog

  alias Reencodarr.FileOperations

  setup do
    tmp = Path.join(System.tmp_dir!(), "fo_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, video} = Fixtures.video_fixture(%{path: Path.join(tmp, "video.mkv")})
    %{tmp: tmp, video: video}
  end

  # ---------------------------------------------------------------------------
  # calculate_intermediate_path/1
  # ---------------------------------------------------------------------------

  describe "calculate_intermediate_path/1" do
    test "inserts .reencoded before .mkv extension" do
      video = Fixtures.build_video_struct(%{path: "/media/movies/The.Movie.mkv"})

      assert FileOperations.calculate_intermediate_path(video) ==
               "/media/movies/The.Movie.reencoded.mkv"
    end

    test "works with .mp4 extension" do
      video = Fixtures.build_video_struct(%{path: "/media/movie.mp4"})
      assert FileOperations.calculate_intermediate_path(video) == "/media/movie.reencoded.mp4"
    end

    test "works with .avi extension" do
      video = Fixtures.build_video_struct(%{path: "/data/clip.avi"})
      assert FileOperations.calculate_intermediate_path(video) == "/data/clip.reencoded.avi"
    end

    test "handles path with multiple dots in filename" do
      video = Fixtures.build_video_struct(%{path: "/media/tv/Show.S01E01.720p.mkv"})

      assert FileOperations.calculate_intermediate_path(video) ==
               "/media/tv/Show.S01E01.720p.reencoded.mkv"
    end

    test "preserves deeply nested directory structure" do
      video = Fixtures.build_video_struct(%{path: "/a/b/c/d/e/f/video.mkv"})

      assert FileOperations.calculate_intermediate_path(video) ==
               "/a/b/c/d/e/f/video.reencoded.mkv"
    end

    test "result has same directory as original" do
      video = Fixtures.build_video_struct(%{path: "/some/dir/file.mkv"})
      result = FileOperations.calculate_intermediate_path(video)
      assert Path.dirname(result) == Path.dirname(video.path)
    end

    test "result has same extension as original" do
      video = Fixtures.build_video_struct(%{path: "/some/dir/file.mkv"})
      result = FileOperations.calculate_intermediate_path(video)
      assert Path.extname(result) == Path.extname(video.path)
    end
  end

  # ---------------------------------------------------------------------------
  # move_file/4 — successful rename (same device)
  # ---------------------------------------------------------------------------

  describe "move_file/4 happy path" do
    test "moves file and returns :ok", %{tmp: tmp, video: video} do
      source = Path.join(tmp, "source.mkv")
      dest = Path.join(tmp, "dest.mkv")
      File.write!(source, "video data")

      capture_log(fn ->
        assert :ok = FileOperations.move_file(source, dest, "Test", video)
      end)

      refute File.exists?(source)
      assert File.read!(dest) == "video data"
    end

    test "preserves binary content after move", %{tmp: tmp, video: video} do
      content = :crypto.strong_rand_bytes(256)
      source = Path.join(tmp, "binary_source.mkv")
      dest = Path.join(tmp, "binary_dest.mkv")
      File.write!(source, content)

      capture_log(fn ->
        assert :ok = FileOperations.move_file(source, dest, "BinaryTest", video)
      end)

      assert File.read!(dest) == content
    end

    test "source file no longer exists after successful move", %{tmp: tmp, video: video} do
      source = Path.join(tmp, "vanish_source.mkv")
      dest = Path.join(tmp, "vanish_dest.mkv")
      File.write!(source, "data")

      capture_log(fn ->
        FileOperations.move_file(source, dest, "Vanish", video)
      end)

      refute File.exists?(source)
    end
  end

  # ---------------------------------------------------------------------------
  # move_file/4 — failure paths
  # ---------------------------------------------------------------------------

  describe "move_file/4 failure paths" do
    test "returns {:error, :enoent} when source does not exist", %{tmp: tmp, video: video} do
      source = Path.join(tmp, "nonexistent.mkv")
      dest = Path.join(tmp, "dest.mkv")

      log =
        capture_log(fn ->
          assert {:error, :enoent} = FileOperations.move_file(source, dest, "Fail", video)
        end)

      assert log =~ "Failed to rename"
    end

    test "returns error when destination directory does not exist", %{tmp: tmp, video: video} do
      source = Path.join(tmp, "src.mkv")
      dest = Path.join(tmp, "no/such/dir/dest.mkv")
      File.write!(source, "data")

      capture_log(fn ->
        assert {:error, _reason} = FileOperations.move_file(source, dest, "BadDir", video)
      end)

      assert File.exists?(source), "source should remain intact on failure"
    end

    test "error log includes context and reason", %{tmp: tmp, video: video} do
      log =
        capture_log(fn ->
          FileOperations.move_file(
            Path.join(tmp, "missing.mkv"),
            Path.join(tmp, "dest.mkv"),
            "ErrorCtx",
            video
          )
        end)

      assert log =~ "[ErrorCtx]"
      assert log =~ "File remains at"
    end
  end

  # ---------------------------------------------------------------------------
  # move_file/4 — EXDEV cross-device fallback (mocked)
  # ---------------------------------------------------------------------------

  describe "move_file/4 EXDEV cross-device fallback" do
    test "succeeds via copy+delete when rename returns :exdev", %{tmp: tmp, video: video} do
      source = Path.join(tmp, "exdev_source.mkv")
      dest = Path.join(tmp, "exdev_dest.mkv")
      File.write!(source, "cross device content")

      :meck.new(File, [:passthrough, :unstick])
      :meck.expect(File, :rename, fn ^source, ^dest -> {:error, :exdev} end)

      capture_log(fn ->
        assert :ok = FileOperations.move_file(source, dest, "EXDEV", video)
      end)

      :meck.unload(File)

      assert File.read!(dest) == "cross device content"
      refute File.exists?(source)
    end

    test "returns error when cross-device copy fails", %{tmp: tmp, video: video} do
      source = Path.join(tmp, "exdev_fail.mkv")
      dest = Path.join(tmp, "exdev_fail_dest.mkv")
      File.write!(source, "data")

      :meck.new(File, [:passthrough, :unstick])
      :meck.expect(File, :rename, fn ^source, ^dest -> {:error, :exdev} end)
      :meck.expect(File, :cp, fn ^source, ^dest -> {:error, :enospc} end)

      log =
        capture_log(fn ->
          assert {:error, :enospc} = FileOperations.move_file(source, dest, "EXDEV", video)
        end)

      :meck.unload(File)

      assert log =~ "Failed to copy"
    end
  end
end
