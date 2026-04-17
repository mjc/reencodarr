defmodule Reencodarr.Media.DeleteBusyTest do
  use Reencodarr.DataCase

  alias Reencodarr.Core.Retry
  alias Reencodarr.Fixtures
  alias Reencodarr.Media
  alias Reencodarr.Media.{Video, Vmaf}
  alias Reencodarr.Repo

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

    :meck.expect(Retry, :retry_on_db_busy, fn fun ->
      send(self(), :retry_on_db_busy_called)
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
