defmodule Reencodarr.Media.MediaInfoTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.MediaInfo
  alias Reencodarr.Media.VideoFileInfo

  describe "parse_hdr/1" do
    test "detects Dolby Vision" do
      result = MediaInfo.parse_hdr(["Dolby Vision / SMPTE ST 2086"])
      assert result =~ "Dolby Vision"
    end

    test "detects HDR" do
      result = MediaInfo.parse_hdr(["HDR10"])
      assert result =~ "HDR"
    end

    test "detects PQ transfer characteristic" do
      result = MediaInfo.parse_hdr(["PQ"])
      assert result =~ "PQ"
    end

    test "detects SMPTE format" do
      result = MediaInfo.parse_hdr(["SMPTE ST 2084"])
      assert result =~ "SMPTE"
    end

    test "joins multiple HDR formats with comma" do
      result = MediaInfo.parse_hdr(["Dolby Vision", "HDR10"])
      assert result =~ "Dolby Vision"
      assert result =~ "HDR10"
      assert result =~ ","
    end

    test "deduplicates repeated formats" do
      result = MediaInfo.parse_hdr(["HDR10", "HDR10"])
      # Only one occurrence, no duplicate comma
      refute result =~ "HDR10, HDR10"
    end

    test "returns empty string for non-HDR formats" do
      assert MediaInfo.parse_hdr(["SDR", "BT.709"]) == ""
    end

    test "ignores nil entries" do
      result = MediaInfo.parse_hdr([nil, "HDR10", nil])
      assert result =~ "HDR10"
    end

    test "returns empty string for empty list" do
      assert MediaInfo.parse_hdr([]) == ""
    end
  end

  describe "parse_hdr_from_video/1" do
    test "returns nil for nil input" do
      assert is_nil(MediaInfo.parse_hdr_from_video(nil))
    end

    test "returns HDR string for video with HDR_Format" do
      video = %{
        "HDR_Format" => "Dolby Vision / SMPTE ST 2086",
        "HDR_Format_Compatibility" => "HDR10"
      }

      result = MediaInfo.parse_hdr_from_video(video)
      assert is_binary(result)
      assert result != ""
    end

    test "returns empty string for SDR video" do
      video = %{"HDR_Format" => nil, "HDR_Format_Compatibility" => nil}
      result = MediaInfo.parse_hdr_from_video(video)
      assert result == ""
    end

    test "handles video map with no HDR fields" do
      result = MediaInfo.parse_hdr_from_video(%{})
      assert result == ""
    end
  end

  describe "has_atmos_format?/1" do
    test "returns true for Atmos string" do
      assert MediaInfo.has_atmos_format?("Dolby Atmos")
      assert MediaInfo.has_atmos_format?("TrueHD Atmos")
    end

    test "returns false for non-Atmos string" do
      refute MediaInfo.has_atmos_format?("DTS-HD MA")
      refute MediaInfo.has_atmos_format?("")
    end

    test "returns false for nil" do
      refute MediaInfo.has_atmos_format?(nil)
    end

    test "returns false for non-string" do
      refute MediaInfo.has_atmos_format?(42)
    end
  end

  describe "parse_subtitles/1" do
    test "splits binary string by /" do
      assert MediaInfo.parse_subtitles("en/fr") == ["en", "fr"]
    end

    test "passes list unchanged" do
      assert MediaInfo.parse_subtitles(["en", "fr"]) == ["en", "fr"]
    end

    test "returns empty list for nil" do
      assert MediaInfo.parse_subtitles(nil) == []
    end
  end

  describe "video_file_info_from_file/2" do
    test "returns VideoFileInfo struct from Sonarr file data" do
      file = %{
        "path" => "/media/show/ep01.mkv",
        "size" => 1_234_567_890,
        "id" => 42,
        "title" => "Episode 1",
        "mediaInfo" => %{
          "videoCodec" => "x265",
          "audioCodec" => "AAC",
          "audioChannels" => "2",
          "resolution" => "1920x1080",
          "overallBitrate" => 5_000_000,
          "videoFps" => 23.976,
          "runTime" => 3600,
          "subtitles" => "en/fr",
          "audioStreamCount" => 1
        }
      }

      result = MediaInfo.video_file_info_from_file(file, :sonarr)

      assert %VideoFileInfo{} = result
      assert result.path == "/media/show/ep01.mkv"
      assert result.size == 1_234_567_890
      assert result.service_id == "42"
      assert result.service_type == :sonarr
      assert result.subtitles == ["en", "fr"]
    end

    test "handles missing mediaInfo gracefully" do
      file = %{
        "path" => "/media/movie.mkv",
        "size" => 500_000,
        "id" => 7
      }

      result = MediaInfo.video_file_info_from_file(file, :radarr)
      assert %VideoFileInfo{} = result
      assert result.path == "/media/movie.mkv"
      assert result.service_type == :radarr
    end
  end
end
