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

  describe "libraries" do
    alias Reencodarr.Media.Library

    import Reencodarr.MediaFixtures

    @invalid_attrs %{monitor: nil, path: nil}

    test "list_libraries/0 returns all libraries" do
      library = library_fixture()
      assert Media.list_libraries() == [library]
    end

    test "get_library!/1 returns the library with given id" do
      library = library_fixture()
      assert Media.get_library!(library.id) == library
    end

    test "create_library/1 with valid data creates a library" do
      valid_attrs = %{monitor: true, path: "some path"}

      assert {:ok, %Library{} = library} = Media.create_library(valid_attrs)
      assert library.monitor == true
      assert library.path == "some path"
    end

    test "create_library/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Media.create_library(@invalid_attrs)
    end

    test "update_library/2 with valid data updates the library" do
      library = library_fixture()
      update_attrs = %{monitor: false, path: "some updated path"}

      assert {:ok, %Library{} = library} = Media.update_library(library, update_attrs)
      assert library.monitor == false
      assert library.path == "some updated path"
    end

    test "update_library/2 with invalid data returns error changeset" do
      library = library_fixture()
      assert {:error, %Ecto.Changeset{}} = Media.update_library(library, @invalid_attrs)
      assert library == Media.get_library!(library.id)
    end

    test "delete_library/1 deletes the library" do
      library = library_fixture()
      assert {:ok, %Library{}} = Media.delete_library(library)
      assert_raise Ecto.NoResultsError, fn -> Media.get_library!(library.id) end
    end

    test "change_library/1 returns a library changeset" do
      library = library_fixture()
      assert %Ecto.Changeset{} = Media.change_library(library)
    end
  end
end
