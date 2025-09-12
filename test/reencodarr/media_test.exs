defmodule Reencodarr.MediaTest do
  use Reencodarr.DataCase, async: true
  import ExUnit.CaptureLog

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  describe "videos" do
    @invalid_video_attrs %{size: nil, path: nil, bitrate: nil}

    test "list_videos/0 returns all videos" do
      {:ok, video} = Fixtures.video_fixture()
      videos = Media.list_videos()

      assert length(videos) == 1
      assert hd(videos).id == video.id
    end

    test "get_video!/1 returns the video with given id" do
      {:ok, video} = Fixtures.video_fixture()

      fetched_video = Media.get_video!(video.id)
      assert fetched_video.id == video.id
      assert fetched_video.path == video.path
    end

    test "create_video/1 with valid data creates a video" do
      attrs = %{
        size: 2_000_000_000,
        path: "/test/video.mkv",
        bitrate: 5_000_000,
        max_audio_channels: 6,
        atmos: false
      }

      video = assert_ok(Media.upsert_video(attrs))
      assert video.size == 2_000_000_000
      assert video.path == "/test/video.mkv"
      assert video.bitrate == 5_000_000
    end

    test "create_video/1 with invalid data returns error changeset" do
      changeset = assert_error(Media.upsert_video(@invalid_video_attrs))

      assert_changeset_error(changeset, %{
        size: ["can't be blank"],
        path: ["can't be blank"]
      })
    end

    test "update_video/2 with valid data updates the video" do
      {:ok, video} = Fixtures.video_fixture()

      update_attrs = %{
        size: 3_000_000_000,
        path: "/updated/path.mkv",
        bitrate: 8_000_000
      }

      updated_video = assert_ok(Media.update_video(video, update_attrs))
      assert updated_video.size == 3_000_000_000
      assert updated_video.path == "/updated/path.mkv"
      assert updated_video.bitrate == 8_000_000
    end

    test "update_video/2 with invalid data returns error changeset" do
      {:ok, video} = Fixtures.video_fixture()

      changeset = assert_error(Media.update_video(video, @invalid_video_attrs))
      assert_changeset_error(changeset, :path, "can't be blank")

      # Video should remain unchanged
      unchanged_video = Media.get_video!(video.id)
      assert unchanged_video.path == video.path
    end

    test "delete_video/1 deletes the video" do
      {:ok, video} = Fixtures.video_fixture()

      assert_ok(Media.delete_video(video))
      assert_raise Ecto.NoResultsError, fn -> Media.get_video!(video.id) end
    end

    test "change_video/1 returns a video changeset" do
      {:ok, video} = Fixtures.video_fixture()
      changeset = Media.change_video(video)

      assert %Ecto.Changeset{} = changeset
      assert changeset.data == video
    end

    # Test factory pattern usage
    test "factory pattern creates videos with custom attributes" do
      {:ok, video} =
        Fixtures.build_video()
        |> Fixtures.with_high_bitrate(20_000_000)
        |> Fixtures.with_path("/test/4k_video.mkv")
        |> Fixtures.create()

      assert video.bitrate == 20_000_000
      assert video.path == "/test/4k_video.mkv"
    end

    test "specialized fixtures create appropriate videos" do
      {:ok, failed_video} = Fixtures.failed_video_fixture()
      assert failed_video.state == :failed

      {:ok, encoded_video} = Fixtures.encoded_video_fixture()
      assert encoded_video.state == :encoded
    end
  end

  describe "libraries" do
    @invalid_library_attrs %{monitor: nil, path: nil}

    test "list_libraries/0 returns all libraries" do
      library = Fixtures.library_fixture()
      libraries = Media.list_libraries()

      assert length(libraries) == 1
      assert hd(libraries).id == library.id
    end

    test "get_library!/1 returns the library with given id" do
      library = Fixtures.library_fixture()

      fetched_library = Media.get_library!(library.id)
      assert fetched_library.id == library.id
      assert fetched_library.path == library.path
    end

    test "create_library/1 with valid data creates a library" do
      attrs = %{monitor: true, path: "/test/library"}

      library = assert_ok(Media.create_library(attrs))
      assert library.monitor == true
      assert library.path == "/test/library"
    end

    test "create_library/1 with invalid data returns error changeset" do
      changeset = assert_error(Media.create_library(@invalid_library_attrs))

      assert_changeset_error(changeset, :monitor, "can't be blank")
      assert_changeset_error(changeset, :path, "can't be blank")
    end

    test "update_library/2 with valid data updates the library" do
      library = Fixtures.library_fixture()
      update_attrs = %{monitor: false, path: "/updated/library"}

      updated_library = assert_ok(Media.update_library(library, update_attrs))
      assert updated_library.monitor == false
      assert updated_library.path == "/updated/library"
    end

    test "update_library/2 with invalid data returns error changeset" do
      library = Fixtures.library_fixture()

      changeset = assert_error(Media.update_library(library, @invalid_library_attrs))
      assert_changeset_error(changeset, :path, "can't be blank")

      # Library should remain unchanged
      unchanged_library = Media.get_library!(library.id)
      assert unchanged_library.path == library.path
    end

    test "delete_library/1 deletes the library" do
      library = Fixtures.library_fixture()

      assert_ok(Media.delete_library(library))
      assert_raise Ecto.NoResultsError, fn -> Media.get_library!(library.id) end
    end

    test "change_library/1 returns a library changeset" do
      library = Fixtures.library_fixture()
      changeset = Media.change_library(library)

      assert %Ecto.Changeset{} = changeset
      assert changeset.data == library
    end

    test "create multiple libraries with fixture helper" do
      libraries = Fixtures.libraries_fixture(3, %{monitor: false})

      assert length(libraries) == 3

      Enum.each(libraries, fn library ->
        assert library.monitor == false
        assert String.starts_with?(library.path, "/test/libraries/library_")
      end)
    end

    @tag :batch_upsert
    test "batch_upsert_videos/1 creates or updates multiple videos in one transaction" do
      # Create a library first
      library = Fixtures.library_fixture()

      # Prepare batch video data
      video_attrs_list = [
        %{
          "path" => "/test/batch_video1.mkv",
          "size" => 1_000_000_000,
          "bitrate" => 4_000_000,
          "library_id" => library.id,
          "max_audio_channels" => 6,
          "atmos" => false
        },
        %{
          "path" => "/test/batch_video2.mkv",
          "size" => 2_000_000_000,
          "bitrate" => 6_000_000,
          "library_id" => library.id,
          "max_audio_channels" => 8,
          "atmos" => true
        },
        %{
          "path" => "/test/batch_video3.mkv",
          "size" => 3_000_000_000,
          "bitrate" => 8_000_000,
          "library_id" => library.id,
          "max_audio_channels" => 2,
          "atmos" => false
        }
      ]

      # Perform batch upsert
      results = Media.batch_upsert_videos(video_attrs_list)

      # Verify all upserts succeeded
      assert length(results) == 3
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Extract the videos
      videos = Enum.map(results, fn {:ok, video} -> video end)

      # Verify videos were created correctly
      assert Enum.at(videos, 0).path == "/test/batch_video1.mkv"
      assert Enum.at(videos, 0).size == 1_000_000_000
      assert Enum.at(videos, 1).path == "/test/batch_video2.mkv"
      assert Enum.at(videos, 1).size == 2_000_000_000
      assert Enum.at(videos, 2).path == "/test/batch_video3.mkv"
      assert Enum.at(videos, 2).size == 3_000_000_000

      # Verify they exist in database
      db_videos = Media.list_videos()
      paths = Enum.map(db_videos, & &1.path)
      assert "/test/batch_video1.mkv" in paths
      assert "/test/batch_video2.mkv" in paths
      assert "/test/batch_video3.mkv" in paths
    end

    test "batch_upsert_videos/1 handles upserts (updates existing videos)" do
      # Create initial videos
      library = Fixtures.library_fixture()

      {:ok, existing_video} =
        Fixtures.video_fixture(%{
          path: "/test/existing.mkv",
          size: 1_000_000_000,
          library_id: library.id
        })

      # Update data for batch upsert
      video_attrs_list = [
        %{
          # Same path - should update
          "path" => "/test/existing.mkv",
          # Different size
          "size" => 2_000_000_000,
          "bitrate" => 7_000_000,
          "library_id" => library.id,
          "max_audio_channels" => 8,
          "atmos" => true
        },
        %{
          # New path - should create
          "path" => "/test/new_video.mkv",
          "size" => 3_000_000_000,
          "bitrate" => 9_000_000,
          "library_id" => library.id,
          "max_audio_channels" => 6,
          "atmos" => false
        }
      ]

      # Perform batch upsert
      results = Media.batch_upsert_videos(video_attrs_list)

      # Verify results
      assert length(results) == 2
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Check updated existing video
      updated_video = Media.get_video!(existing_video.id)
      # Updated
      assert updated_video.size == 2_000_000_000
      # Same
      assert updated_video.path == "/test/existing.mkv"
      # Updated
      assert updated_video.atmos == true

      # Check new video was created
      all_videos = Media.list_videos()
      new_video = Enum.find(all_videos, &(&1.path == "/test/new_video.mkv"))
      assert new_video != nil
      assert new_video.size == 3_000_000_000
    end

    test "batch_upsert_videos/1 handles errors gracefully" do
      # Create a library first
      library = Fixtures.library_fixture()

      # Test with invalid data - valid path but missing required size
      video_attrs_list = [
        %{
          "path" => "/test/valid.mkv",
          "size" => 1_000_000_000,
          "bitrate" => 4_000_000,
          "library_id" => library.id,
          "max_audio_channels" => 6,
          "atmos" => false
        },
        %{
          "path" => "/test/invalid.mkv",
          # Missing required size field
          "bitrate" => 4_000_000,
          "library_id" => library.id,
          "max_audio_channels" => 6,
          "atmos" => false
        }
      ]

      # Perform batch upsert
      capture_log(fn ->
        results = Media.batch_upsert_videos(video_attrs_list)

        # Should have one success and one error
        assert length(results) == 2
        assert match?({:ok, _}, Enum.at(results, 0))
        assert match?({:error, _}, Enum.at(results, 1))
      end)
    end
  end

  describe "vmafs" do
    @invalid_vmaf_attrs %{crf: nil, score: nil, video_id: nil}

    test "list_vmafs/0 returns all vmafs" do
      vmaf = Fixtures.vmaf_fixture()
      vmafs = Media.list_vmafs()

      assert length(vmafs) == 1
      assert hd(vmafs).id == vmaf.id
    end

    test "get_vmaf!/1 returns the vmaf with given id" do
      vmaf = Fixtures.vmaf_fixture()

      fetched_vmaf = Media.get_vmaf!(vmaf.id)
      assert fetched_vmaf.id == vmaf.id
      assert fetched_vmaf.crf == vmaf.crf
    end

    test "create_vmaf/1 with valid data creates a vmaf" do
      {:ok, video} = Fixtures.video_fixture()

      attrs = %{
        video_id: video.id,
        crf: 28.0,
        score: 95.5,
        params: ["--preset", "medium"]
      }

      vmaf = assert_ok(Media.create_vmaf(attrs))
      assert vmaf.crf == 28.0
      assert vmaf.score == 95.5
      assert vmaf.video_id == video.id
    end

    test "create_vmaf/1 with invalid data returns error changeset" do
      changeset = assert_error(Media.create_vmaf(@invalid_vmaf_attrs))

      assert_changeset_error(changeset, %{
        crf: ["can't be blank"],
        score: ["can't be blank"],
        params: ["can't be blank"]
      })
    end

    test "update_vmaf/2 with valid data updates the vmaf" do
      vmaf = Fixtures.vmaf_fixture()
      update_attrs = %{crf: 30.0, score: 90.5}

      updated_vmaf = assert_ok(Media.update_vmaf(vmaf, update_attrs))
      assert updated_vmaf.crf == 30.0
      assert updated_vmaf.score == 90.5
    end

    test "update_vmaf/2 with invalid data returns error changeset" do
      vmaf = Fixtures.vmaf_fixture()

      changeset = assert_error(Media.update_vmaf(vmaf, @invalid_vmaf_attrs))
      assert_changeset_error(changeset, :crf, "can't be blank")

      # VMAF should remain unchanged
      unchanged_vmaf = Media.get_vmaf!(vmaf.id)
      assert unchanged_vmaf.crf == vmaf.crf
    end

    test "delete_vmaf/1 deletes the vmaf" do
      vmaf = Fixtures.vmaf_fixture()

      assert_ok(Media.delete_vmaf(vmaf))
      assert_raise Ecto.NoResultsError, fn -> Media.get_vmaf!(vmaf.id) end
    end

    test "change_vmaf/1 returns a vmaf changeset" do
      vmaf = Fixtures.vmaf_fixture()
      changeset = Media.change_vmaf(vmaf)

      assert %Ecto.Changeset{} = changeset
      assert changeset.data.id == vmaf.id
    end

    test "vmaf series fixture creates CRF search results" do
      {:ok, video} = Fixtures.video_fixture()
      vmafs = Fixtures.vmaf_series_fixture(video, [24, 26, 28, 30, 32])

      assert length(vmafs) == 5

      # Should have decreasing quality scores with higher CRF
      sorted_vmafs = Enum.sort_by(vmafs, & &1.crf)
      scores = Enum.map(sorted_vmafs, & &1.score)

      assert scores == Enum.sort(scores, :desc), "VMAF scores should decrease with higher CRF"
    end

    test "optimal vmaf fixture creates realistic encoding results" do
      # 5GB source
      {:ok, video} = Fixtures.video_fixture(%{size: 5_000_000_000})
      optimal_vmaf = Fixtures.optimal_vmaf_fixture(video, 95.0)

      assert optimal_vmaf.score == 95.0
      assert optimal_vmaf.crf == 28.0
      assert optimal_vmaf.video_id == video.id
    end
  end
end
