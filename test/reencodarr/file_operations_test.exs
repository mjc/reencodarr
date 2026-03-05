defmodule Reencodarr.FileOperationsTest do
  use ExUnit.Case, async: true
  alias Reencodarr.FileOperations

  # Minimal video struct for passing to move_file
  defp make_video(id \\ 1), do: %{id: id, path: "/fake/path/video.mkv"}

  defp tmp_path(suffix) do
    Path.join(System.tmp_dir!(), "file_ops_test_#{System.unique_integer([:positive])}_#{suffix}")
  end

  describe "calculate_intermediate_path/1" do
    test "appends .reencoded before the extension" do
      video = %{path: "/media/movies/The.Movie.mkv"}
      result = FileOperations.calculate_intermediate_path(video)
      assert result == "/media/movies/The.Movie.reencoded.mkv"
    end

    test "works with mp4 files" do
      video = %{path: "/media/movies/The.Movie.mp4"}
      result = FileOperations.calculate_intermediate_path(video)
      assert result == "/media/movies/The.Movie.reencoded.mp4"
    end

    test "preserves directory structure" do
      video = %{path: "/mnt/deep/nested/path/to/file.mkv"}
      result = FileOperations.calculate_intermediate_path(video)
      assert result == "/mnt/deep/nested/path/to/file.reencoded.mkv"
    end

    test "works with file that has multiple dots in name" do
      video = %{path: "/media/tv/Show.S01E01.720p.mkv"}
      result = FileOperations.calculate_intermediate_path(video)
      assert result == "/media/tv/Show.S01E01.720p.reencoded.mkv"
    end

    test "works with file in root-adjacent directory" do
      video = %{path: "/videos/movie.mkv"}
      result = FileOperations.calculate_intermediate_path(video)
      assert result == "/videos/movie.reencoded.mkv"
    end

    test "result has same directory as original" do
      video = %{path: "/some/dir/file.mkv"}
      result = FileOperations.calculate_intermediate_path(video)
      assert Path.dirname(result) == Path.dirname(video.path)
    end

    test "result has same extension as original" do
      video = %{path: "/some/dir/file.mkv"}
      result = FileOperations.calculate_intermediate_path(video)
      assert Path.extname(result) == Path.extname(video.path)
    end

    test "result basename contains .reencoded" do
      video = %{path: "/some/dir/file.mkv"}
      result = FileOperations.calculate_intermediate_path(video)
      assert String.contains?(Path.basename(result), ".reencoded")
    end
  end

  describe "move_file/4 - successful rename" do
    test "returns :ok and moves file" do
      src = tmp_path("src.mkv")
      dst = tmp_path("dst.mkv")
      File.write!(src, "video data")

      on_exit(fn ->
        File.rm(src)
        File.rm(dst)
      end)

      assert :ok = FileOperations.move_file(src, dst, "test", make_video())
      assert File.exists?(dst)
      refute File.exists?(src)
    end

    test "content is preserved after move" do
      src = tmp_path("src_content.mkv")
      dst = tmp_path("dst_content.mkv")
      File.write!(src, "some important video bytes")

      on_exit(fn ->
        File.rm(src)
        File.rm(dst)
      end)

      :ok = FileOperations.move_file(src, dst, "test", make_video())
      assert File.read!(dst) == "some important video bytes"
    end
  end

  describe "move_file/4 - error handling" do
    test "returns error tuple when source file does not exist" do
      src = tmp_path("nonexistent.mkv")
      dst = tmp_path("dst_nonexistent.mkv")

      on_exit(fn -> File.rm(dst) end)

      result = FileOperations.move_file(src, dst, "test", make_video())
      assert {:error, _reason} = result
    end

    test "returns error tuple when destination directory does not exist" do
      src = tmp_path("src_bad_dst.mkv")
      File.write!(src, "data")
      dst = "/nonexistent_directory_xyz/output.mkv"

      on_exit(fn -> File.rm(src) end)

      result = FileOperations.move_file(src, dst, "test", make_video())
      assert {:error, _reason} = result
    end
  end
end
