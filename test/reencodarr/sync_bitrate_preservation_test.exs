defmodule Reencodarr.SyncBitratePreservationTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.Fixtures

  alias Reencodarr.{Media, Sync}

  describe "sync bitrate preservation" do
    setup do
      library = Fixtures.library_fixture()
      %{library: library}
    end

    test "preserves analyzed bitrate when file size doesn't change", %{library: library} do
      # Create a video with analyzed bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movie.mkv",
          # 2GB
          size: 2_000_000_000,
          # 5 Mbps (analyzed)
          bitrate: 5_000_000,
          service_id: "123",
          service_type: :sonarr,
          library_id: library.id
        })

      # Simulate sync update with same file size but different metadata
      file_info = %{
        "path" => "/test/movie.mkv",
        # Same size
        "size" => 2_000_000_000,
        "id" => "123",
        "mediaInfo" => %{
          "audioCodec" => "EAC3",
          "videoBitrate" => 4_000_000,
          "audioBitrate" => 500_000,
          "audioChannels" => 6,
          "videoCodec" => "HEVC",
          "width" => 1920,
          "height" => 1080,
          "videoDynamicRange" => "HDR10",
          "videoDynamicRangeType" => "HDR10",
          "audioLanguages" => ["eng"],
          "subtitles" => ["eng"]
        },
        "videoFps" => 23.976,
        "overallBitrate" => 4_500_000,
        "runTime" => 7200,
        "sceneName" => "Test Movie 2024"
      }

      # Perform sync update
      Sync.upsert_video_from_file(file_info, :sonarr)

      # Reload video and check bitrate is preserved
      updated_video = Media.get_video!(video.id)

      assert updated_video.bitrate == 5_000_000,
             "Bitrate should be preserved when file size doesn't change"

      assert updated_video.size == 2_000_000_000
      assert updated_video.path == "/test/movie.mkv"
    end

    test "resets bitrate when file size changes", %{library: library} do
      # Create a video with analyzed bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movie2.mkv",
          # 2GB
          size: 2_000_000_000,
          # 5 Mbps (analyzed)
          bitrate: 5_000_000,
          service_id: "124",
          service_type: :sonarr,
          library_id: library.id
        })

      # Simulate sync update with different file size
      file_info = %{
        "path" => "/test/movie2.mkv",
        # Different size (3GB)
        "size" => 3_000_000_000,
        "id" => "124",
        "mediaInfo" => %{
          "audioCodec" => "EAC3",
          "videoBitrate" => 6_000_000,
          "audioBitrate" => 500_000,
          "audioChannels" => 6,
          "videoCodec" => "HEVC",
          "width" => 1920,
          "height" => 1080,
          "videoDynamicRange" => "HDR10",
          "videoDynamicRangeType" => "HDR10",
          "audioLanguages" => ["eng"],
          "subtitles" => ["eng"]
        },
        "videoFps" => 23.976,
        "overallBitrate" => 6_500_000,
        "runTime" => 7200,
        "sceneName" => "Test Movie 2024"
      }

      # Perform sync update
      Sync.upsert_video_from_file(file_info, :sonarr)

      # Reload video and check bitrate is updated
      updated_video = Media.get_video!(video.id)

      assert updated_video.bitrate == 6_500_000,
             "Bitrate should be updated when file size changes"

      assert updated_video.size == 3_000_000_000
      assert updated_video.path == "/test/movie2.mkv"
    end

    test "allows bitrate reset when explicitly set to 0", %{library: library} do
      # Create a video with analyzed bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movie3.mkv",
          # 2GB
          size: 2_000_000_000,
          # 5 Mbps (analyzed)
          bitrate: 5_000_000,
          service_id: "125",
          service_type: :sonarr,
          library_id: library.id
        })

      # Create VideoFileInfo with bitrate 0 but NOT TrueHD/EAC3 (so it goes through normal processing)
      file_info = %Reencodarr.Media.VideoFileInfo{
        path: "/test/movie3.mkv",
        # Same size
        size: 2_000_000_000,
        service_id: "125",
        service_type: :sonarr,
        # Not TrueHD/EAC3, so will go through normal processing
        audio_codec: "AAC",
        # Explicitly 0 - needs analysis
        bitrate: 0,
        audio_channels: 6,
        video_codec: "HEVC",
        resolution: "1920x1080",
        video_fps: 23.976,
        video_dynamic_range: "HDR10",
        video_dynamic_range_type: "HDR10",
        audio_stream_count: 1,
        overall_bitrate: 0,
        run_time: 7200,
        subtitles: ["eng"],
        title: "Test Movie 2024"
      }

      # Perform sync update
      Sync.upsert_video_from_file(file_info, :sonarr)

      # Reload video and check bitrate is reset to 0 for re-analysis
      updated_video = Media.get_video!(video.id)
      # Should be 0 because bitrate was explicitly set to 0 and it inserts then triggers analyzer
      assert updated_video.bitrate == 0 or is_nil(updated_video.bitrate),
             "Bitrate should be reset when explicitly set to 0"

      assert updated_video.size == 2_000_000_000
      assert updated_video.path == "/test/movie3.mkv"
    end
  end
end
