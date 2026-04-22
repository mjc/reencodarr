defmodule Reencodarr.Media.DeleteBusyTest do
  use Reencodarr.DataCase

  alias Reencodarr.Core.Retry
  alias Reencodarr.Fixtures
  alias Reencodarr.Media
  alias Reencodarr.Media.{Video, Vmaf}
  alias Reencodarr.Repo

  test "delete_videos_with_nonexistent_paths/1 deletes missing videos under available libraries" do
    library_path = Path.join(System.tmp_dir!(), "library_#{System.unique_integer([:positive])}")
    File.mkdir_p!(library_path)
    on_exit(fn -> File.rm_rf(library_path) end)

    library = Fixtures.library_fixture(%{path: library_path})
    missing_path = Path.join(library_path, "missing.mkv")
    {:ok, video} = Fixtures.video_fixture(%{path: missing_path, library_id: library.id})

    assert {:ok, 1} =
             Media.delete_videos_with_nonexistent_paths(
               scan_batch_size: 1,
               delete_batch_size: 1,
               file_check_concurrency: 1,
               batch_pause_ms: 0
             )

    assert Repo.get(Video, video.id) == nil
  end

  test "delete_videos_with_nonexistent_paths/1 skips videos when the library root is unavailable" do
    library_path =
      Path.join(System.tmp_dir!(), "missing_library_#{System.unique_integer([:positive])}")

    library = Fixtures.library_fixture(%{path: library_path})
    missing_path = Path.join(library_path, "missing.mkv")
    {:ok, video} = Fixtures.video_fixture(%{path: missing_path, library_id: library.id})

    assert {:ok, 0} =
             Media.delete_videos_with_nonexistent_paths(
               scan_batch_size: 1,
               delete_batch_size: 1,
               file_check_concurrency: 1,
               batch_pause_ms: 0
             )

    assert Repo.get(Video, video.id) != nil
  end

  test "delete_videos_with_nonexistent_paths/0 uses the database busy retry wrapper" do
    :meck.new(Retry, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(Retry)
      catch
        :error, {:not_mocked, Retry} -> :ok
        :exit, {:not_mocked, Retry} -> :ok
      end
    end)

    missing_path = create_temp_file("missing video", ".mkv")
    {:ok, video} = Fixtures.video_fixture(%{path: missing_path})
    _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
    File.rm!(missing_path)

    :meck.expect(Retry, :retry_on_db_busy, fn fun, opts ->
      send(self(), :retry_on_db_busy_called)
      assert opts[:label] == :media_delete_videos_and_vmafs
      fun.()
    end)

    assert {:ok, 1} = Media.delete_videos_with_nonexistent_paths()
    assert_received :retry_on_db_busy_called
    assert Repo.get(Video, video.id) == nil

    remaining_vmafs =
      from(v in Vmaf, where: v.video_id == ^video.id)
      |> Repo.aggregate(:count)

    assert remaining_vmafs == 0
  end
end
