defmodule Reencodarr.Media.MediaInfoConversionTest do
  use ExUnit.Case, async: true
  alias Reencodarr.Media.{MediaInfo, VideoFileInfo}

  describe "MediaInfo.from_service_file/2" do
    test "converts Sonarr file data to MediaInfo JSON format" do
      sonarr_file = %{
        "id" => 123,
        "path" => "/path/to/show.mkv",
        "size" => 1_234_567_890,
        "runTime" => 2520,
        "overallBitrate" => 8000,
        "videoFps" => 23.976,
        "sceneName" => "Show.S01E01.1080p.HDTV.x264-GROUP",
        "title" => "Episode Title",
        "mediaInfo" => %{
          "width" => "1920",
          "height" => "1080",
          "videoCodec" => "h264",
          "videoDynamicRange" => "HDR10",
          "videoDynamicRangeType" => "HDR10",
          "audioCodec" => "truehd",
          "audioChannels" => "7.1",
          "audioLanguages" => ["en", "es"],
          "subtitles" => ["en", "es", "fr"]
        }
      }

      result = MediaInfo.from_service_file(sonarr_file, :sonarr)

      assert %{"media" => %{"track" => tracks}} = result
      assert length(tracks) == 3

      # Check General track
      general_track = Enum.find(tracks, &(&1["@type"] == "General"))
      assert general_track["AudioCount"] == 2
      assert general_track["OverallBitRate"] == 8000
      assert general_track["Duration"] == 2520
      assert general_track["FileSize"] == 1_234_567_890
      assert general_track["TextCount"] == 3
      assert general_track["VideoCount"] == 1
      assert general_track["Title"] == "Show.S01E01.1080p.HDTV.x264-GROUP"

      # Check Video track
      video_track = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video_track["FrameRate"] == 23.976
      assert video_track["Height"] == 1080
      assert video_track["Width"] == 1920
      assert video_track["HDR_Format"] == "HDR10"
      assert video_track["HDR_Format_Compatibility"] == "HDR10"
      assert video_track["CodecID"] == "h264"

      # Check Audio track
      audio_track = Enum.find(tracks, &(&1["@type"] == "Audio"))
      assert audio_track["CodecID"] == "truehd"
      assert audio_track["Channels"] == "7.1"
    end

    test "converts Radarr file data to MediaInfo JSON format" do
      radarr_file = %{
        "id" => 456,
        "path" => "/path/to/movie.mkv",
        "size" => 2_345_678_901,
        "runTime" => 7320,
        "overallBitrate" => 12_000,
        "videoFps" => 24.0,
        "sceneName" => "Movie.2023.2160p.UHD.BluRay.x265-GROUP",
        "title" => "Movie Title",
        "mediaInfo" => %{
          "width" => 3840,
          "height" => 2160,
          "videoCodec" => "hevc",
          "videoDynamicRange" => "HDR10+",
          "videoDynamicRangeType" => "HDR10+",
          "audioCodec" => "eac3",
          "audioChannels" => "5.1",
          "audioLanguages" => "en/de",
          "subtitles" => "en/de/fr/es"
        }
      }

      result = MediaInfo.from_service_file(radarr_file, :radarr)

      assert %{"media" => %{"track" => tracks}} = result
      assert length(tracks) == 3

      # Check General track
      general_track = Enum.find(tracks, &(&1["@type"] == "General"))
      assert general_track["AudioCount"] == 2
      assert general_track["OverallBitRate"] == 12_000
      assert general_track["Duration"] == 7320
      assert general_track["FileSize"] == 2_345_678_901
      assert general_track["TextCount"] == 4
      assert general_track["VideoCount"] == 1
      assert general_track["Title"] == "Movie.2023.2160p.UHD.BluRay.x265-GROUP"

      # Check Video track
      video_track = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video_track["FrameRate"] == 24.0
      assert video_track["Height"] == 2160
      assert video_track["Width"] == 3840
      assert video_track["HDR_Format"] == "HDR10+"
      assert video_track["HDR_Format_Compatibility"] == "HDR10+"
      assert video_track["CodecID"] == "hevc"

      # Check Audio track
      audio_track = Enum.find(tracks, &(&1["@type"] == "Audio"))
      assert audio_track["CodecID"] == "eac3"
      assert audio_track["Channels"] == "5.1"
    end

    test "handles missing or malformed data gracefully" do
      minimal_file = %{
        "id" => 789,
        "path" => "/path/to/minimal.mkv",
        "size" => 100_000_000,
        "mediaInfo" => %{}
      }

      result = MediaInfo.from_service_file(minimal_file, :sonarr)

      assert %{"media" => %{"track" => tracks}} = result
      assert length(tracks) == 3

      # Check that it doesn't crash and provides default values
      general_track = Enum.find(tracks, &(&1["@type"] == "General"))
      assert general_track["AudioCount"] == 0
      assert general_track["OverallBitRate"] == 0
      assert general_track["TextCount"] == 0
      assert general_track["VideoCount"] == 1

      video_track = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video_track["Height"] == 0
      assert video_track["Width"] == 0
    end
  end

  describe "MediaInfo.from_service_file_to_struct/2" do
    test "converts service file data directly to MediaInfo struct" do
      sonarr_file = %{
        "id" => 123,
        "path" => "/path/to/show.mkv",
        "size" => 1_234_567_890,
        "runTime" => 2520,
        "overallBitrate" => 8000,
        "videoFps" => 23.976,
        "sceneName" => "Show.S01E01.1080p.HDTV.x264-GROUP",
        "mediaInfo" => %{
          "width" => "1920",
          "height" => "1080",
          "videoCodec" => "h264",
          "audioCodec" => "truehd",
          "audioChannels" => "7.1",
          "audioLanguages" => ["en", "es"],
          "subtitles" => ["en", "es", "fr"]
        }
      }

      result = MediaInfo.from_service_file_to_struct(sonarr_file, :sonarr)

      assert %MediaInfo{} = result
      assert result.media.track != nil
      assert length(result.media.track) == 3

      # Verify we can extract data using the helper functions
      video_track = MediaInfo.extract_video_track(result)
      assert MediaInfo.get_resolution(video_track) == {1920, 1080}
      assert MediaInfo.get_video_codec(video_track) == "h264"

      audio_track = MediaInfo.extract_audio_track(result)
      assert MediaInfo.get_audio_codec(audio_track) == "truehd"
      assert MediaInfo.get_audio_channels(audio_track) == "7.1"

      general_track = MediaInfo.extract_general_track(result)
      assert MediaInfo.get_overall_bitrate(general_track) == 8000
      assert MediaInfo.get_audio_count(general_track) == 2
    end
  end

  describe "VideoFileInfo conversion" do
    test "converts VideoFileInfo to MediaInfo struct" do
      video_file_info = %VideoFileInfo{
        path: "/path/to/video.mkv",
        size: 1_000_000_000,
        service_id: "123",
        service_type: :sonarr,
        audio_codec: "eac3",
        video_codec: "hevc",
        resolution: {1920, 1080},
        video_fps: 24.0,
        video_dynamic_range: "HDR10",
        video_dynamic_range_type: "HDR10",
        audio_channels: "5.1",
        audio_stream_count: 1,
        overall_bitrate: 10_000,
        bitrate: 10_000,
        run_time: 3600,
        subtitles: ["en", "fr"],
        title: "Video Title"
      }

      result = MediaInfo.from_video_file_info_to_struct(video_file_info)

      assert %MediaInfo{} = result
      assert length(result.media.track) == 3

      # Verify the conversion preserved the data correctly
      video_track = MediaInfo.extract_video_track(result)
      assert MediaInfo.get_resolution(video_track) == {1920, 1080}
      assert MediaInfo.get_video_codec(video_track) == "hevc"
      assert MediaInfo.get_fps(video_track) == 24.0

      audio_track = MediaInfo.extract_audio_track(result)
      assert MediaInfo.get_audio_codec(audio_track) == "eac3"
      assert MediaInfo.get_audio_channels(audio_track) == "5.1"

      general_track = MediaInfo.extract_general_track(result)
      assert MediaInfo.get_overall_bitrate(general_track) == 10_000
      assert MediaInfo.get_duration(general_track) == 3600
    end
  end
end
