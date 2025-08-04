defmodule Reencodarr.Media.MediaInfoSimplifiedTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.MediaInfo

  describe "to_video_params/2" do
    test "extracts basic video metadata from complete mediainfo" do
      mediainfo = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "Duration" => "3600.000",
              "FileSize" => "536870912",
              "OverallBitRate" => "1000000",
              "AudioCount" => "2",
              "VideoCount" => "1",
              "TextCount" => "0",
              "Title" => "Test Video"
            },
            %{
              "@type" => "Video",
              "Width" => "1920",
              "Height" => "1080",
              "FrameRate" => "23.976",
              "CodecID" => "V_MPEG4/ISO/AVC",
              "HDR_Format" => "",
              "HDR_Format_Compatibility" => ""
            },
            %{
              "@type" => "Audio",
              "CodecID" => "A_AAC",
              "Channels" => "2",
              "Format_Commercial_IfAny" => ""
            }
          ]
        }
      }

      result = MediaInfo.to_video_params(mediainfo, "/test/file.mkv")

      assert result["width"] == 1920
      assert result["height"] == 1080
      assert result["duration"] == 3600.0
      assert result["size"] == 536_870_912
      assert result["bitrate"] == 1_000_000
      assert result["frame_rate"] == 23.976
      assert result["title"] == "Test Video"
      assert result["video_codecs"] == ["V_MPEG4/ISO/AVC"]
      assert result["audio_codecs"] == ["A_AAC"]
      assert result["hdr"] == ""
    end

    test "handles empty mediainfo gracefully" do
      result = MediaInfo.to_video_params(%{}, "/test/empty.mkv")

      assert result["width"] == 0
      assert result["height"] == 0
      assert result["duration"] == 0.0
      assert result["size"] == 0
      assert result["bitrate"] == 0
      assert result["title"] == "empty.mkv"
      assert result["video_codecs"] == []
      assert result["audio_codecs"] == []
    end

    test "handles nil mediainfo gracefully" do
      result = MediaInfo.to_video_params(nil, "/test/nil.mkv")

      assert result["width"] == 0
      assert result["height"] == 0
      assert result["duration"] == 0.0
      assert result["size"] == 0
      assert result["bitrate"] == 0
      assert result["title"] == "nil.mkv"
      assert result["video_codecs"] == []
      assert result["audio_codecs"] == []
    end
  end

  describe "video_file_info_from_file/2" do
    test "converts file data to VideoFileInfo struct" do
      file_data = %{
        "id" => 123,
        "path" => "/test/video.mkv",
        "size" => 1024,
        "title" => "Test Movie",
        "mediaInfo" => %{
          "audioCodec" => "AAC",
          "videoCodec" => "AVC",
          "audioChannels" => 2,
          "resolution" => "1920x1080",
          "videoDynamicRange" => "SDR",
          "videoDynamicRangeType" => "SDR",
          "audioStreamCount" => 1,
          "overallBitrate" => 5_000_000,
          "videoBitrate" => 4_500_000,
          "audioBitrate" => 500_000,
          "subtitles" => ["eng", "spa"],
          "videoFps" => 23.976,
          "runTime" => 7200
        }
      }

      result = MediaInfo.video_file_info_from_file(file_data, :sonarr)

      assert result.path == "/test/video.mkv"
      assert result.size == 1024
      assert result.service_id == "123"
      assert result.service_type == :sonarr
      assert result.audio_codec == "A_AAC"
      assert result.video_codec == "V_MPEG4/ISO/AVC"
      assert result.audio_channels == 2
      assert result.resolution == {1920, 1080}
      assert result.video_fps == 23.976
      assert result.video_dynamic_range == "SDR"
      assert result.video_dynamic_range_type == "SDR"
      assert result.audio_stream_count == 1
      assert result.overall_bitrate == 5_000_000
      assert result.run_time == 7200
      assert result.subtitles == ["eng", "spa"]
      assert result.title == "Test Movie"
    end

    test "handles missing mediaInfo gracefully" do
      file_data = %{
        "id" => 123,
        "path" => "/test/no_media_info.mkv",
        "size" => 1024,
        "title" => "Test Movie"
      }

      result = MediaInfo.video_file_info_from_file(file_data, :radarr)

      assert result.path == "/test/no_media_info.mkv"
      assert result.size == 1024
      assert result.service_id == "123"
      assert result.service_type == :radarr
      assert result.title == "Test Movie"
      # Should handle missing mediaInfo gracefully
      assert result.audio_codec == ""
      assert result.video_codec == ""
      assert result.resolution == {0, 0}
    end
  end
end
