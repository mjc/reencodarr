defmodule Reencodarr.SyncTest do
  use Reencodarr.DataCase, async: true
  import ExUnit.CaptureLog

  alias Reencodarr.{Media, Sync}
  alias Reencodarr.Media.VideoFileInfo

  setup do
    library = Fixtures.library_fixture(%{path: "/test"})
    %{library: library}
  end

  defp build_file_info(overrides \\ %{}) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      path: "/test/shows/episode_#{unique_id}.mkv",
      size: 2_500_000_000,
      service_id: "svc_#{unique_id}",
      service_type: :sonarr,
      audio_codec: "AAC",
      bitrate: 8_000_000,
      audio_channels: 2,
      video_codec: "H.264",
      resolution: "1920x1080",
      video_fps: 23.976,
      video_dynamic_range: nil,
      video_dynamic_range_type: nil,
      audio_stream_count: 1,
      overall_bitrate: 8_500_000,
      run_time: 2700,
      subtitles: ["eng"],
      title: "Test Episode",
      date_added: DateTime.utc_now()
    }

    struct(VideoFileInfo, Map.merge(defaults, overrides))
  end

  # ── upsert_video_from_file/2 with VideoFileInfo ──
  # Note: upsert_video_from_file wraps result in Repo.transaction,
  # returning {:ok, {:ok, video}} on success.

  describe "upsert_video_from_file/2 with VideoFileInfo" do
    test "creates a video from valid VideoFileInfo", %{library: _library} do
      info = build_file_info()

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_file(info, :sonarr)
        assert video.path == info.path
        assert video.size == info.size
      end)
    end

    test "sets service_type to sonarr", %{library: _library} do
      info = build_file_info(%{service_type: :sonarr})

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_file(info, :sonarr)
        assert video.service_type == :sonarr
      end)
    end

    test "sets service_type to radarr", %{library: _library} do
      info = build_file_info(%{service_type: :radarr})

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_file(info, :radarr)
        assert video.service_type == :radarr
      end)
    end

    test "logs warning when size is nil", %{library: _library} do
      info = build_file_info(%{size: nil})

      log =
        capture_log(fn ->
          Sync.upsert_video_from_file(info, :sonarr)
        end)

      assert log =~ "File size is missing"
    end

    test "still creates video even when size is nil", %{library: _library} do
      info = build_file_info(%{size: nil})

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_file(info, :sonarr)
        assert video.path == info.path
      end)
    end

    test "updates existing video when path matches and size changes", %{library: _library} do
      info = build_file_info()

      capture_log(fn ->
        assert {:ok, {:ok, original}} = Sync.upsert_video_from_file(info, :sonarr)

        updated_info = %{info | size: 5_000_000_000, bitrate: 16_000_000}
        assert {:ok, {:ok, updated}} = Sync.upsert_video_from_file(updated_info, :sonarr)

        assert updated.id == original.id
        assert updated.size == 5_000_000_000
      end)
    end

    test "preserves analyzed bitrate when size unchanged and bitrate nonzero", %{
      library: _library
    } do
      info = build_file_info(%{bitrate: 10_000_000})

      capture_log(fn ->
        assert {:ok, {:ok, original}} = Sync.upsert_video_from_file(info, :sonarr)

        # Re-upsert same file with same size — bitrate should be preserved
        resync_info = %{info | bitrate: 10_000_000}
        assert {:ok, {:ok, resynced}} = Sync.upsert_video_from_file(resync_info, :sonarr)

        assert resynced.id == original.id
        assert resynced.bitrate == original.bitrate
      end)
    end

    test "assigns library_id when path matches a library", %{library: library} do
      info = build_file_info(%{path: "#{library.path}/shows/ep.mkv"})

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_file(info, :sonarr)
        assert video.library_id == library.id
      end)
    end

    test "sets needs_analysis state for zero bitrate", %{library: _library} do
      info = build_file_info(%{bitrate: 0, overall_bitrate: 0})

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_file(info, :sonarr)
        assert video.state == :needs_analysis
      end)
    end
  end

  # ── upsert_video_from_file/2 with raw map ──

  describe "upsert_video_from_file/2 with raw map" do
    test "creates video from map with path and size keys", %{library: _library} do
      unique_id = System.unique_integer([:positive])

      raw = %{
        "path" => "/test/movies/raw_movie_#{unique_id}.mkv",
        "size" => 3_000_000_000,
        "id" => "raw_#{unique_id}",
        "overallBitrate" => 7_000_000,
        "videoFps" => 24.0,
        "runTime" => 5400,
        "dateAdded" => "2024-06-01T12:00:00Z",
        "mediaInfo" => %{
          "audioCodec" => "AAC",
          "videoCodec" => "H.264",
          "width" => 1920,
          "height" => 1080,
          "audioLanguages" => ["eng"]
        }
      }

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_file(raw, :radarr)
        assert video.path == raw["path"]
        assert video.size == 3_000_000_000
      end)
    end
  end

  # ── batch_upsert_videos/2 ──

  describe "batch_upsert_videos/2" do
    test "returns :ok for empty list", %{library: _library} do
      capture_log(fn ->
        assert :ok = Sync.batch_upsert_videos([], :sonarr)
      end)
    end

    test "creates videos from list of raw file maps", %{library: _library} do
      files =
        for i <- 1..3 do
          unique_id = System.unique_integer([:positive])

          %{
            "path" => "/test/batch/episode_#{i}_#{unique_id}.mkv",
            "size" => 1_000_000_000 + i * 100_000,
            "id" => "batch_#{unique_id}",
            "overallBitrate" => 5_000_000,
            "dateAdded" => "2024-01-0#{i}T00:00:00Z"
          }
        end

      capture_log(fn ->
        assert :ok = Sync.batch_upsert_videos(files, :sonarr)
      end)

      # Verify each video was created
      for file <- files do
        {:ok, video} = Media.get_video_by_path(file["path"])
        assert video.size == file["size"]
      end
    end

    test "creates videos from list of VideoFileInfo structs", %{library: _library} do
      infos = for _ <- 1..2, do: build_file_info()

      capture_log(fn ->
        assert :ok = Sync.batch_upsert_videos(infos, :sonarr)
      end)

      for info <- infos do
        {:ok, video} = Media.get_video_by_path(info.path)
        assert video.path == info.path
      end
    end

    test "skips unknown file formats gracefully", %{library: _library} do
      files = [
        build_file_info(),
        # unknown format — will be nil and filtered out
        :not_a_file,
        build_file_info()
      ]

      log =
        capture_log(fn ->
          assert :ok = Sync.batch_upsert_videos(files, :sonarr)
        end)

      assert log =~ "Unknown file format"
    end
  end

  # ── delete_video_and_vmafs/1 ──

  describe "delete_video_and_vmafs/1" do
    test "deletes an existing video by path", %{library: library} do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/delete_unit/movie.mkv",
          service_id: "del_unit_1",
          library_id: library.id
        })

      assert :ok = Sync.delete_video_and_vmafs(video.path)
      assert Media.get_video(video.id) == nil
    end

    test "deletes associated vmafs along with the video", %{library: library} do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/delete_unit/with_vmafs.mkv",
          service_id: "del_vmaf_1",
          library_id: library.id
        })

      Fixtures.vmaf_fixture(%{video_id: video.id, crf: 24.0, score: 96.0})
      Fixtures.vmaf_fixture(%{video_id: video.id, crf: 28.0, score: 93.0})

      assert length(Media.get_vmafs_for_video(video.id)) == 2

      assert :ok = Sync.delete_video_and_vmafs(video.path)

      assert Media.get_video(video.id) == nil
      assert Media.get_vmafs_for_video(video.id) == []
    end

    test "returns :ok when path does not match any video" do
      assert :ok = Sync.delete_video_and_vmafs("/nonexistent/path/video.mkv")
    end
  end

  # ── upsert_video_from_service_file/2 ──

  describe "upsert_video_from_service_file/2" do
    test "creates video from sonarr service file", %{library: _library} do
      unique_id = System.unique_integer([:positive])

      file = %{
        "path" => "/test/service/sonarr_ep_#{unique_id}.mkv",
        "size" => 1_500_000_000,
        "id" => "svc_sonarr_#{unique_id}",
        "overallBitrate" => 4_000_000,
        "dateAdded" => "2024-03-10T08:00:00Z",
        "mediaInfo" => %{
          "audioCodec" => "EAC3",
          "videoCodec" => "H.264",
          "width" => 1920,
          "height" => 1080,
          "audioLanguages" => ["eng"]
        }
      }

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_service_file(file, :sonarr)
        assert video.path == file["path"]
        assert video.bitrate == 4_000_000
        assert video.service_type == :sonarr
        assert is_map(video.mediainfo)
      end)
    end

    test "creates video from radarr service file", %{library: _library} do
      unique_id = System.unique_integer([:positive])

      file = %{
        "path" => "/test/service/radarr_movie_#{unique_id}.mkv",
        "size" => 4_000_000_000,
        "id" => "svc_radarr_#{unique_id}",
        "overallBitrate" => 12_000_000,
        "dateAdded" => "2024-05-20T15:00:00Z",
        "mediaInfo" => %{
          "audioCodec" => "TrueHD",
          "videoCodec" => "HEVC",
          "width" => 3840,
          "height" => 2160,
          "audioLanguages" => ["eng", "spa"]
        }
      }

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_service_file(file, :radarr)
        assert video.service_type == :radarr
        assert video.size == 4_000_000_000
      end)
    end

    test "defaults bitrate to 0 when overallBitrate is missing", %{library: _library} do
      unique_id = System.unique_integer([:positive])

      file = %{
        "path" => "/test/service/no_bitrate_#{unique_id}.mkv",
        "size" => 800_000_000,
        "id" => "svc_nb_#{unique_id}",
        "dateAdded" => "2024-01-01T00:00:00Z",
        "mediaInfo" => %{
          "audioCodec" => "AAC",
          "videoCodec" => "H.264",
          "width" => 1280,
          "height" => 720,
          "audioLanguages" => ["eng"]
        }
      }

      capture_log(fn ->
        assert {:ok, {:ok, video}} = Sync.upsert_video_from_service_file(file, :sonarr)
        # Zero bitrate is stored as nil and triggers needs_analysis
        assert video.state == :needs_analysis
      end)
    end
  end

  # ── refresh_and_rename_from_video/1 edge cases ──

  describe "refresh_and_rename_from_video/1" do
    test "returns error when service_type is nil" do
      assert {:error, "No service type for video"} =
               Sync.refresh_and_rename_from_video(%{service_type: nil, service_id: "123"})
    end

    test "returns error when service_id is nil" do
      assert {:error, "No service_id for video"} =
               Sync.refresh_and_rename_from_video(%{service_type: :sonarr, service_id: nil})
    end
  end
end
