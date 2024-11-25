defmodule Reencodarr.MediaTest do
  use Reencodarr.DataCase

  alias Reencodarr.Media

  describe "videos" do
    alias Reencodarr.Media.Video

    import Reencodarr.MediaFixtures

    @invalid_attrs %{size: nil, path: nil, bitrate: nil}

    test "list_videos/0 returns all videos" do
      video = video_fixture()
      assert Media.list_videos() == [video]
    end

    test "get_video!/1 returns the video with given id" do
      video = video_fixture()
      assert Media.get_video!(video.id) == video
    end

    test "create_video/1 with valid data creates a video" do
      valid_attrs = %{size: 42, path: "some path", bitrate: 42}

      assert {:ok, %Video{} = video} = Media.create_video(valid_attrs)
      assert video.size == 42
      assert video.path == "some path"
      assert video.bitrate == 42
    end

    test "create_video/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Media.create_video(@invalid_attrs)
    end

    test "update_video/2 with valid data updates the video" do
      video = video_fixture()
      update_attrs = %{size: 43, path: "some updated path", bitrate: 43}

      assert {:ok, %Video{} = video} = Media.update_video(video, update_attrs)
      assert video.size == 43
      assert video.path == "some updated path"
      assert video.bitrate == 43
    end

    test "update_video/2 with invalid data returns error changeset" do
      video = video_fixture()
      assert {:error, %Ecto.Changeset{}} = Media.update_video(video, @invalid_attrs)
      assert video == Media.get_video!(video.id)
    end

    test "delete_video/1 deletes the video" do
      video = video_fixture()
      assert {:ok, %Video{}} = Media.delete_video(video)
      assert_raise Ecto.NoResultsError, fn -> Media.get_video!(video.id) end
    end

    test "change_video/1 returns a video changeset" do
      video = video_fixture()
      assert %Ecto.Changeset{} = Media.change_video(video)
    end
  end
end
