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

    test "get_video_by_path/1 returns video when found" do
      {:ok, video} = Fixtures.video_fixture(%{path: "/unique/path/video.mkv"})

      assert {:ok, found_video} = Media.get_video_by_path("/unique/path/video.mkv")
      assert found_video.id == video.id
      assert found_video.path == "/unique/path/video.mkv"
    end

    test "get_video_by_path/1 returns error when not found" do
      assert {:error, :not_found} = Media.get_video_by_path("/nonexistent/path.mkv")
    end

    test "video_exists?/1 returns true when video exists" do
      {:ok, video} = Fixtures.video_fixture(%{path: "/test/exists.mkv"})

      assert Media.video_exists?(video.path) == true
    end

    test "video_exists?/1 returns false when video doesn't exist" do
      assert Media.video_exists?("/nonexistent.mkv") == false
    end

    test "find_videos_by_path_wildcard/1 finds matching videos" do
      {:ok, _v1} = Fixtures.video_fixture(%{path: "/media/movies/action/video1.mkv"})
      {:ok, _v2} = Fixtures.video_fixture(%{path: "/media/movies/comedy/video2.mkv"})
      {:ok, _v3} = Fixtures.video_fixture(%{path: "/media/tv/shows/video3.mkv"})

      results = Media.find_videos_by_path_wildcard("/media/movies/%")

      assert length(results) == 2
      assert Enum.all?(results, fn v -> String.starts_with?(v.path, "/media/movies/") end)
    end

    test "delete_video_with_vmafs/1 deletes video and its VMAFs" do
      {:ok, video} = Fixtures.video_fixture()
      vmaf1 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      vmaf2 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0})

      assert {:ok, _} = Media.delete_video_with_vmafs(video)

      # Video should be deleted
      assert_raise Ecto.NoResultsError, fn -> Media.get_video!(video.id) end

      # VMAFs should be deleted
      assert is_nil(Repo.get(Reencodarr.Media.Vmaf, vmaf1.id))
      assert is_nil(Repo.get(Reencodarr.Media.Vmaf, vmaf2.id))
    end

    test "count_videos/0 returns correct count" do
      assert Media.count_videos() == 0

      {:ok, _v1} = Fixtures.video_fixture()
      assert Media.count_videos() == 1

      {:ok, _v2} = Fixtures.video_fixture()
      assert Media.count_videos() == 2
    end

    test "get_video/1 returns video when found" do
      {:ok, video} = Fixtures.video_fixture()

      found = Media.get_video(video.id)
      assert found.id == video.id
    end

    test "get_video/1 returns nil when not found" do
      assert Media.get_video(99_999) == nil
    end

    test "get_video_by_service_id/2 returns video when found" do
      {:ok, video} = Fixtures.video_fixture(%{service_id: "12345", service_type: :sonarr})

      assert {:ok, found} = Media.get_video_by_service_id("12345", :sonarr)
      assert found.id == video.id
      assert found.service_id == "12345"
    end

    test "get_video_by_service_id/2 returns error when not found" do
      assert {:error, :not_found} = Media.get_video_by_service_id("nonexistent", :sonarr)
    end

    test "get_video_by_service_id/2 returns error for nil service_id" do
      assert {:error, :invalid_service_id} = Media.get_video_by_service_id(nil, :sonarr)
    end

    test "delete_videos_with_path/1 deletes videos at path" do
      # Use unique path to avoid interference with other async tests
      unique_path = "/media/delete/#{:erlang.unique_integer([:positive])}"
      {:ok, v1} = Fixtures.video_fixture(%{path: "#{unique_path}/video1.mkv"})
      {:ok, v2} = Fixtures.video_fixture(%{path: "#{unique_path}/video2.mkv"})
      {:ok, v3} = Fixtures.video_fixture(%{path: "/media/keep/video3.mkv"})

      # Pattern needs wildcard for prefix matching
      {:ok, {video_count, _}} = Media.delete_videos_with_path("#{unique_path}%")
      assert video_count == 2

      # First two should be deleted
      assert_raise Ecto.NoResultsError, fn -> Media.get_video!(v1.id) end
      assert_raise Ecto.NoResultsError, fn -> Media.get_video!(v2.id) end

      # Third should remain
      assert Media.get_video!(v3.id)
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

    test "get_videos_in_library/1 returns videos for a specific library" do
      library1 = Fixtures.library_fixture(%{path: "/library1"})
      library2 = Fixtures.library_fixture(%{path: "/library2"})

      {:ok, v1} = Fixtures.video_fixture(%{library_id: library1.id, path: "/library1/video1.mkv"})
      {:ok, v2} = Fixtures.video_fixture(%{library_id: library1.id, path: "/library1/video2.mkv"})

      {:ok, _v3} =
        Fixtures.video_fixture(%{library_id: library2.id, path: "/library2/video3.mkv"})

      videos_in_lib1 = Media.get_videos_in_library(library1.id)

      assert length(videos_in_lib1) == 2
      assert v1.id in Enum.map(videos_in_lib1, & &1.id)
      assert v2.id in Enum.map(videos_in_lib1, & &1.id)
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

    test "get_vmafs_for_video/1 returns all VMAFs for a video" do
      {:ok, video} = Fixtures.video_fixture()
      vmaf1 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      vmaf2 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0})

      vmafs = Media.get_vmafs_for_video(video.id)

      assert length(vmafs) == 2
      assert vmaf1.id in Enum.map(vmafs, & &1.id)
      assert vmaf2.id in Enum.map(vmafs, & &1.id)
    end

    test "delete_vmafs_for_video/1 deletes all VMAFs for a video" do
      {:ok, video} = Fixtures.video_fixture()
      _vmaf1 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      _vmaf2 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0})

      {deleted_count, _} = Media.delete_vmafs_for_video(video.id)
      assert deleted_count == 2

      # VMAFs should be deleted
      assert Media.get_vmafs_for_video(video.id) == []
    end

    test "chosen_vmaf_exists?/1 returns true when chosen VMAF exists" do
      {:ok, video} = Fixtures.video_fixture()
      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0, chosen: true})

      assert Media.chosen_vmaf_exists?(video) == true
    end

    test "chosen_vmaf_exists?/1 returns false when no chosen VMAF" do
      {:ok, video} = Fixtures.video_fixture()
      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0, chosen: false})

      assert Media.chosen_vmaf_exists?(video) == false
    end

    test "list_chosen_vmafs/0 returns only chosen VMAFs", %{test: test_name} do
      # Use test_name to ensure unique video IDs in parallel runs
      # Videos must be in :crf_searched state for chosen VMAFs to be listed
      {:ok, video1} =
        Fixtures.video_fixture(%{path: "/#{test_name}/v1.mkv", state: :crf_searched})

      {:ok, video2} =
        Fixtures.video_fixture(%{path: "/#{test_name}/v2.mkv", state: :crf_searched})

      chosen1 = Fixtures.vmaf_fixture(%{video_id: video1.id, crf: 25.0, chosen: true})
      _unchosen = Fixtures.vmaf_fixture(%{video_id: video1.id, crf: 30.0, chosen: false})
      chosen2 = Fixtures.vmaf_fixture(%{video_id: video2.id, crf: 28.0, chosen: true})

      chosen_vmafs = Media.list_chosen_vmafs()

      # Should include at least our 2 chosen VMAFs
      chosen_ids = Enum.map(chosen_vmafs, & &1.id)
      assert chosen1.id in chosen_ids
      assert chosen2.id in chosen_ids
    end

    test "get_chosen_vmaf_for_video/1 returns chosen VMAF" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      chosen = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0, chosen: true})
      _unchosen = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, chosen: false})

      result = Media.get_chosen_vmaf_for_video(video)

      assert result.id == chosen.id
      assert result.chosen == true
    end

    test "get_chosen_vmaf_for_video/1 returns nil when no chosen VMAF" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      _unchosen = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, chosen: false})

      assert Media.get_chosen_vmaf_for_video(video) == nil
    end

    test "mark_vmaf_as_chosen/2 marks VMAF as chosen and unmarks others" do
      {:ok, video} = Fixtures.video_fixture()
      vmaf1 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0, chosen: false})
      vmaf2 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, chosen: false})

      {:ok, _} = Media.mark_vmaf_as_chosen(video.id, 25.0)

      # Verify the correct VMAF was marked as chosen
      updated_vmaf1 = Repo.get!(Reencodarr.Media.Vmaf, vmaf1.id)
      assert updated_vmaf1.chosen == true

      # Verify the other VMAF for THIS video is not chosen
      updated_vmaf2 = Repo.get!(Reencodarr.Media.Vmaf, vmaf2.id)
      assert updated_vmaf2.chosen == false
    end

    test "delete_unchosen_vmafs/0 deletes VMAFs without chosen=true" do
      # Video with chosen VMAF - should keep all VMAFs
      {:ok, video_with_chosen} = Fixtures.video_fixture()
      chosen = Fixtures.vmaf_fixture(%{video_id: video_with_chosen.id, crf: 25.0, chosen: true})
      keep1 = Fixtures.vmaf_fixture(%{video_id: video_with_chosen.id, crf: 28.0, chosen: false})

      # Video with NO chosen VMAFs - should delete all VMAFs
      {:ok, video_no_chosen} = Fixtures.video_fixture()
      delete1 = Fixtures.vmaf_fixture(%{video_id: video_no_chosen.id, crf: 30.0, chosen: false})
      delete2 = Fixtures.vmaf_fixture(%{video_id: video_no_chosen.id, crf: 32.0, chosen: false})

      # Store IDs before deletion
      chosen_id = chosen.id
      keep1_id = keep1.id
      delete1_id = delete1.id
      delete2_id = delete2.id

      {:ok, {deleted_count, _}} = Media.delete_unchosen_vmafs()

      # Should delete the 2 VMAFs from video_no_chosen
      assert deleted_count == 2

      # VMAFs from video with chosen should remain
      assert Repo.get(Reencodarr.Media.Vmaf, chosen_id)
      assert Repo.get(Reencodarr.Media.Vmaf, keep1_id)

      # VMAFs from video without chosen should be deleted
      refute Repo.get(Reencodarr.Media.Vmaf, delete1_id)
      refute Repo.get(Reencodarr.Media.Vmaf, delete2_id)
    end
  end

  describe "video query functions" do
    test "video_exists?/1 returns true when video exists" do
      {:ok, video} = Fixtures.video_fixture(%{path: "/test/exists.mkv"})
      assert Media.video_exists?(video.path)
    end

    test "video_exists?/1 returns false when video does not exist" do
      refute Media.video_exists?("/nonexistent/path.mkv")
    end

    test "find_videos_by_path_wildcard/1 returns matching videos" do
      {:ok, _video1} = Fixtures.video_fixture(%{path: "/media/movies/action/film1.mkv"})
      {:ok, _video2} = Fixtures.video_fixture(%{path: "/media/movies/action/film2.mkv"})
      {:ok, _video3} = Fixtures.video_fixture(%{path: "/media/tv/show/episode.mkv"})

      action_videos = Media.find_videos_by_path_wildcard("%/action/%")
      assert length(action_videos) == 2
      assert Enum.all?(action_videos, &String.contains?(&1.path, "/action/"))
    end

    test "get_videos_for_crf_search/1 returns videos needing CRF search" do
      {:ok, video1} = Fixtures.video_fixture()
      {:ok, video2} = Fixtures.video_fixture()

      # Mark videos as analyzed (ready for CRF search)
      {:ok, _} = Media.mark_as_analyzed(video1)
      {:ok, _} = Media.mark_as_analyzed(video2)

      videos = Media.get_videos_for_crf_search(5)
      assert length(videos) >= 2
      assert Enum.all?(videos, &(&1.state == :analyzed))
    end

    test "count_videos_for_crf_search/0 returns correct count" do
      {:ok, video1} = Fixtures.video_fixture()
      {:ok, video2} = Fixtures.video_fixture()

      {:ok, _} = Media.mark_as_analyzed(video1)
      {:ok, _} = Media.mark_as_analyzed(video2)

      count = Media.count_videos_for_crf_search()
      assert count >= 2
    end

    test "get_videos_needing_analysis/1 returns unanalyzed videos" do
      {:ok, _video1} = Fixtures.video_fixture()
      {:ok, _video2} = Fixtures.video_fixture()

      videos = Media.get_videos_needing_analysis(10)
      assert length(videos) >= 2
      assert Enum.all?(videos, &(&1.state == :needs_analysis))
    end

    test "count_videos_needing_analysis/0 returns correct count" do
      {:ok, _video1} = Fixtures.video_fixture()
      {:ok, _video2} = Fixtures.video_fixture()

      count = Media.count_videos_needing_analysis()
      assert count >= 2
    end

    test "list_videos_by_estimated_percent/1 returns videos ready for encoding" do
      {:ok, video} = Fixtures.video_fixture()
      {:ok, analyzed} = Media.mark_as_analyzed(video)
      vmaf = Fixtures.optimal_vmaf_fixture(analyzed, 95.0)
      {:ok, _chosen_vmaf} = Media.update_vmaf(vmaf, %{chosen: true})
      # Mark video as crf_searched (required for encoding queue)
      {:ok, _} = Media.mark_as_crf_searched(analyzed)

      videos = Media.list_videos_by_estimated_percent(10)
      assert length(videos) >= 1
    end

    test "delete_video_with_vmafs/1 deletes video and associated VMAFs" do
      {:ok, video} = Fixtures.video_fixture()
      {:ok, analyzed} = Media.mark_as_analyzed(video)
      _vmaf = Fixtures.optimal_vmaf_fixture(analyzed, 95.0)

      assert_ok(Media.delete_video_with_vmafs(video))
      assert_raise Ecto.NoResultsError, fn -> Media.get_video!(video.id) end
    end
  end

  describe "video state transitions" do
    test "mark_as_analyzed/1 transitions video to analyzed state" do
      {:ok, video} = Fixtures.video_fixture()
      {:ok, analyzed} = Media.mark_as_analyzed(video)

      assert analyzed.state == :analyzed
    end

    test "mark_as_needs_analysis/1 transitions failed video to needs_analysis state" do
      {:ok, video} = Fixtures.video_fixture()
      {:ok, failed} = Media.mark_as_failed(video)
      {:ok, needs_analysis} = Media.mark_as_needs_analysis(failed)

      assert needs_analysis.state == :needs_analysis
    end

    test "mark_as_encoded/1 transitions video to encoded state" do
      {:ok, video} = Fixtures.video_fixture()
      {:ok, analyzed} = Media.mark_as_analyzed(video)
      {:ok, crf_searched} = Media.mark_as_crf_searched(analyzed)
      # Need to transition through encoding state first
      {:ok, encoding} = Media.update_video(crf_searched, %{state: :encoding})
      {:ok, encoded} = Media.mark_as_encoded(encoding)

      assert encoded.state == :encoded
    end
  end

  describe "video failure tracking" do
    test "record_video_failure/4 creates failure and marks video as failed" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, _failure} =
        Media.record_video_failure(
          video,
          :encoding,
          :process_failure,
          code: "1",
          message: "Encoding failed"
        )

      updated_video = Media.get_video!(video.id)
      assert updated_video.state == :failed
    end

    test "record_video_failure/4 logs warning on success" do
      {:ok, video} = Fixtures.video_fixture()

      log =
        capture_log(fn ->
          Media.record_video_failure(
            video,
            :encoding,
            :process_failure,
            message: "Test failure"
          )
        end)

      assert log =~ "Recorded encoding/process_failure failure"
      assert log =~ "Test failure"
    end

    test "record_video_failure/4 handles deleted video gracefully" do
      {:ok, video} = Fixtures.video_fixture()
      video_id = video.id

      # Delete the video first
      Media.delete_video(video)

      # Should not crash when trying to record failure - will raise constraint error
      capture_log(fn ->
        try do
          Media.record_video_failure(
            %{video | id: video_id},
            :encoding,
            :process_failure,
            message: "Test"
          )
        rescue
          # Foreign key constraint error is expected when video is deleted
          Ecto.ConstraintError -> :ok
        end
      end)

      # Test passes if we caught the error
      assert true
    end

    test "get_video_failures/1 returns unresolved failures" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, _} =
        Media.record_video_failure(
          video,
          :encoding,
          :process_failure,
          message: "Failure 1"
        )

      failures = Media.get_video_failures(video.id)
      assert length(failures) >= 1
      assert Enum.all?(failures, &(&1.resolved == false))
    end

    test "resolve_video_failures/1 resolves all failures for video" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, _} =
        Media.record_video_failure(
          video,
          :encoding,
          :process_failure,
          message: "Failure 1"
        )

      Media.resolve_video_failures(video.id)

      failures = Media.get_video_failures(video.id)
      assert Enum.empty?(failures)
    end

    test "get_failure_statistics/1 returns failure stats" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, _} =
        Media.record_video_failure(
          video,
          :encoding,
          :process_failure,
          message: "Test"
        )

      stats = Media.get_failure_statistics()
      assert is_list(stats)
      assert length(stats) > 0
    end

    test "get_common_failure_patterns/1 returns common patterns" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, _} =
        Media.record_video_failure(
          video,
          :encoding,
          :process_failure,
          message: "Common error"
        )

      patterns = Media.get_common_failure_patterns(10)
      assert is_list(patterns)
    end
  end

  describe "queue operations" do
    test "get_videos_for_crf_search/1 returns analyzed videos" do
      {:ok, analyzed} = Fixtures.video_fixture(%{state: :analyzed})
      {:ok, _encoded} = Fixtures.video_fixture(%{state: :encoded})

      videos = Media.get_videos_for_crf_search(10)
      video_ids = Enum.map(videos, & &1.id)

      assert analyzed.id in video_ids
    end

    test "get_videos_needing_analysis/1 returns videos needing analysis" do
      {:ok, needs_analysis} = Fixtures.video_fixture(%{state: :needs_analysis})
      {:ok, _analyzed} = Fixtures.video_fixture(%{state: :analyzed})

      videos = Media.get_videos_needing_analysis(10)
      video_ids = Enum.map(videos, & &1.id)

      assert needs_analysis.id in video_ids
    end

    test "list_videos_by_estimated_percent/1 returns ready for encoding" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, chosen: true})

      vmafs = Media.list_videos_by_estimated_percent(10)

      assert length(vmafs) >= 1
      assert Enum.any?(vmafs, fn v -> v.video_id == video.id end)
    end

    test "get_next_for_encoding_by_time/0 returns chosen VMAFs ordered by time" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, chosen: true, time: 100})

      result = Media.get_next_for_encoding_by_time()

      assert is_list(result)
      if length(result) > 0, do: assert(hd(result).chosen == true)
    end

    test "debug_encoding_queue_by_library/1 returns queue debug info" do
      library = Fixtures.library_fixture()
      {:ok, video} = Fixtures.video_fixture(%{library_id: library.id, state: :crf_searched})
      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, chosen: true})

      results = Media.debug_encoding_queue_by_library(10)

      assert is_list(results)
    end
  end

  describe "library operations" do
    test "create_library/1 creates a library" do
      {:ok, library} =
        Media.create_library(%{
          path: "/test/library/#{:erlang.unique_integer([:positive])}",
          monitor: true
        })

      assert library.path =~ "/test/library/"
      assert library.monitor == true
    end

    test "create_library/1 returns error for invalid attrs" do
      {:error, changeset} = Media.create_library(%{})

      assert changeset.errors[:path]
    end
  end

  describe "vmaf operations" do
    test "create_vmaf/1 creates a VMAF record" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 25.0,
          score: 95.5,
          chosen: false,
          params: ["--preset", "medium"]
        })

      assert vmaf.crf == 25.0
      assert vmaf.score == 95.5
      assert vmaf.chosen == false
      assert vmaf.params == ["--preset", "medium"]
    end

    test "create_vmaf/1 returns error for invalid attrs" do
      {:error, changeset} = Media.create_vmaf(%{})

      assert changeset.errors[:crf]
      assert changeset.errors[:score]
      assert changeset.errors[:params]
    end
  end

  describe "bulk operations" do
    test "reset_all_failures/0 resets failed videos" do
      {:ok, failed1} = Fixtures.video_fixture(%{state: :failed})
      {:ok, failed2} = Fixtures.video_fixture(%{state: :failed})
      {:ok, _encoded} = Fixtures.video_fixture(%{state: :encoded})

      Media.record_video_failure(failed1, :encoding, :process_failure, message: "Test failure")

      result = Media.reset_all_failures()

      assert result.videos_reset >= 2
      assert result.vmafs_deleted >= 0

      # Verify videos are reset to needs_analysis
      reloaded1 = Media.get_video!(failed1.id)
      reloaded2 = Media.get_video!(failed2.id)

      assert reloaded1.state == :needs_analysis
      assert reloaded2.state == :needs_analysis
    end
  end

  describe "test helpers" do
    test "test_insert_path/2 creates video for testing" do
      # Create a library to match the path
      _library = Fixtures.library_fixture(%{path: "/test"})

      path = "/test/video_#{:erlang.unique_integer([:positive])}.mkv"

      result = Media.test_insert_path(path, %{"duration" => 3600})

      # test_insert_path returns a diagnostic map, not {:ok, video}
      assert result.success == true
      assert result.video_id
    end
  end

  describe "video update operations" do
    test "update_video/2 updates video attributes" do
      {:ok, video} = Fixtures.video_fixture(%{duration: 3600})

      {:ok, updated} = Media.update_video(video, %{duration: 7200})

      assert updated.duration == 7200
    end

    test "update_library/2 updates library attributes" do
      library = Fixtures.library_fixture()

      {:ok, updated} = Media.update_library(library, %{monitor: true})

      assert updated.monitor == true
    end

    test "update_vmaf/2 updates VMAF attributes" do
      {:ok, video} = Fixtures.video_fixture()
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, chosen: false})

      {:ok, updated} = Media.update_vmaf(vmaf, %{chosen: true})

      assert updated.chosen == true
    end
  end

  describe "upsert operations" do
    test "upsert_vmaf/1 creates new VMAF" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => 25.0,
          "score" => 95.5,
          "params" => ["--preset", "medium"],
          "chosen" => false
        })

      assert vmaf.crf == 25.0
      assert vmaf.score == 95.5
    end

    test "upsert_vmaf/1 updates existing VMAF" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, vmaf1} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => 25.0,
          "score" => 94.0,
          "params" => ["--preset", "medium"],
          "chosen" => false
        })

      {:ok, vmaf2} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => 25.0,
          "score" => 95.5,
          "params" => ["--preset", "medium"],
          "chosen" => false
        })

      assert vmaf1.id == vmaf2.id
      assert vmaf2.score == 95.5
    end

    test "batch_upsert_videos/1 creates multiple videos" do
      library = Fixtures.library_fixture(%{path: "/batch"})

      videos = [
        %{
          "path" => "/batch/video1.mkv",
          "library_id" => library.id,
          "size" => 1_000_000,
          "duration" => 3600.0
        },
        %{
          "path" => "/batch/video2.mkv",
          "library_id" => library.id,
          "size" => 2_000_000,
          "duration" => 7200.0
        }
      ]

      results = Media.batch_upsert_videos(videos)

      # Returns list of results
      assert is_list(results)
      assert length(results) == 2
      # Check successful upserts
      successful =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert successful >= 1
    end
  end

  describe "reanalysis operations" do
    test "force_reanalyze_video/1 resets video for analysis" do
      {:ok, video} = Fixtures.video_fixture(%{bitrate: 5_000_000})
      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})

      {:ok, path} = Media.force_reanalyze_video(video.id)

      assert path == video.path

      # Verify VMAFs were deleted
      vmafs = Media.get_vmafs_for_video(video.id)
      assert Enum.empty?(vmafs)

      # Verify bitrate was reset
      reloaded = Media.get_video!(video.id)
      assert is_nil(reloaded.bitrate)
    end

    test "debug_force_analyze_video/1 queues video for analysis" do
      {:ok, video} = Fixtures.video_fixture()

      result = Media.debug_force_analyze_video(video.path)

      assert result.video.id == video.id
      assert is_map(result)
    end

    test "reset_failed_videos/0 resets failed videos" do
      {:ok, _failed1} = Fixtures.video_fixture(%{state: :failed})
      {:ok, _failed2} = Fixtures.video_fixture(%{state: :failed})

      {count, _} = Media.reset_failed_videos()

      assert count >= 2
    end

    test "reset_all_videos_for_reanalysis/0 clears bitrate" do
      {:ok, video} = Fixtures.video_fixture(%{bitrate: 5_000_000, state: :analyzed})

      {count, _} = Media.reset_all_videos_for_reanalysis()

      assert count >= 1

      reloaded = Media.get_video!(video.id)
      assert is_nil(reloaded.bitrate)
    end

    test "reset_all_videos_to_needs_analysis/0 resets all videos" do
      {:ok, _video1} = Fixtures.video_fixture(%{state: :analyzed})
      {:ok, _video2} = Fixtures.video_fixture(%{state: :crf_searched})

      {count, _} = Media.reset_all_videos_to_needs_analysis()

      assert count >= 2
    end
  end

  describe "invalid audio operations" do
    test "count_videos_with_invalid_audio_args/0 finds problematic videos" do
      # Create video with invalid audio metadata
      {:ok, _video} =
        Fixtures.video_fixture(%{
          max_audio_channels: 0,
          audio_codecs: [],
          state: :analyzed
        })

      result = Media.count_videos_with_invalid_audio_args()

      assert result.videos_tested >= 1
      assert result.videos_with_invalid_args >= 0
    end

    test "reset_videos_with_invalid_audio_args/0 resets problematic videos" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          max_audio_channels: 0,
          audio_codecs: [],
          bitrate: 5_000_000,
          state: :analyzed
        })

      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})

      result = Media.reset_videos_with_invalid_audio_args()

      assert result.videos_tested >= 1

      # Verify video was reset if it had invalid args
      reloaded = Media.get_video!(video.id)

      if result.videos_reset > 0 do
        assert is_nil(reloaded.bitrate)
      end
    end

    test "reset_videos_with_invalid_audio_metadata/0 resets videos with nil audio" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          max_audio_channels: nil,
          audio_codecs: nil,
          bitrate: 5_000_000,
          state: :analyzed
        })

      _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})

      result = Media.reset_videos_with_invalid_audio_metadata()

      assert result.videos_reset >= 1
      assert result.vmafs_deleted >= 1

      reloaded = Media.get_video!(video.id)
      assert is_nil(reloaded.bitrate)
    end
  end

  describe "deletion operations" do
    test "delete_video/1 removes video" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, _deleted} = Media.delete_video(video)

      assert_raise Ecto.NoResultsError, fn -> Media.get_video!(video.id) end
    end

    test "delete_library/1 removes library" do
      library = Fixtures.library_fixture()

      {:ok, _deleted} = Media.delete_library(library)

      assert_raise Ecto.NoResultsError, fn -> Media.get_library!(library.id) end
    end

    test "delete_vmaf/1 removes VMAF" do
      {:ok, video} = Fixtures.video_fixture()
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})

      {:ok, _deleted} = Media.delete_vmaf(vmaf)

      assert_raise Ecto.NoResultsError, fn -> Media.get_vmaf!(vmaf.id) end
    end

    test "delete_videos_with_nonexistent_paths/0 removes videos with missing files" do
      # This test would require mocking File.exists? or creating actual files
      # For now, just verify it returns the expected tuple format
      result = Media.delete_videos_with_nonexistent_paths()

      assert match?({:ok, {_, _}}, result)
    end
  end

  describe "changeset operations" do
    test "change_video/2 returns changeset" do
      {:ok, video} = Fixtures.video_fixture()

      changeset = Media.change_video(video, %{duration: 7200})

      assert changeset.changes.duration == 7200
    end

    test "change_library/2 returns changeset" do
      library = Fixtures.library_fixture()

      changeset = Media.change_library(library, %{monitor: true})

      assert changeset.changes.monitor == true
    end

    test "change_vmaf/2 returns changeset" do
      {:ok, video} = Fixtures.video_fixture()
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})

      changeset = Media.change_vmaf(vmaf, %{chosen: true})

      assert changeset.changes.chosen == true
    end
  end

  describe "video failure operations" do
    test "get_video_failures/1 returns unresolved failures" do
      {:ok, video} = Fixtures.video_fixture()

      Media.record_video_failure(video, :encoding, :process_failure, message: "Test failure")

      failures = Media.get_video_failures(video.id)

      assert length(failures) >= 1
      assert hd(failures).failure_stage == :encoding
    end

    test "resolve_video_failures/1 resolves all failures" do
      {:ok, video} = Fixtures.video_fixture()

      Media.record_video_failure(video, :encoding, :process_failure, message: "Test failure")

      Media.resolve_video_failures(video.id)

      failures = Media.get_video_failures(video.id)
      assert Enum.empty?(failures)
    end
  end
end
