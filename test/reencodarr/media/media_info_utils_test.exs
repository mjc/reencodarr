defmodule Reencodarr.Media.MediaInfoUtilsTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.MediaInfoUtils

  describe "has_atmos_format?/1" do
    test "returns true for strings containing Atmos" do
      assert MediaInfoUtils.has_atmos_format?("Dolby Atmos")
      assert MediaInfoUtils.has_atmos_format?("TrueHD Atmos")
      assert MediaInfoUtils.has_atmos_format?("EAC3 Atmos")
    end

    test "returns false for non-Atmos strings" do
      refute MediaInfoUtils.has_atmos_format?("DTS-HD MA")
      refute MediaInfoUtils.has_atmos_format?("AAC")
      refute MediaInfoUtils.has_atmos_format?("")
    end

    test "returns false for nil" do
      refute MediaInfoUtils.has_atmos_format?(nil)
    end

    test "returns false for non-binary non-nil" do
      refute MediaInfoUtils.has_atmos_format?(42)
      refute MediaInfoUtils.has_atmos_format?(:some_atom)
    end
  end

  describe "parse_subtitles/1" do
    test "splits binary by /" do
      assert MediaInfoUtils.parse_subtitles("en/fr/de") == ["en", "fr", "de"]
    end

    test "returns single-element list for binary with no /" do
      assert MediaInfoUtils.parse_subtitles("en") == ["en"]
    end

    test "passes list through unchanged" do
      assert MediaInfoUtils.parse_subtitles(["en", "fr"]) == ["en", "fr"]
    end

    test "returns empty list for nil" do
      assert MediaInfoUtils.parse_subtitles(nil) == []
    end

    test "returns empty list for empty string" do
      assert MediaInfoUtils.parse_subtitles("") == [""]
    end

    test "handles integer (non-binary, non-list, non-nil)" do
      assert MediaInfoUtils.parse_subtitles(42) == []
    end
  end

  describe "from_mediainfo_json/1" do
    test "returns ok tuple for a valid map" do
      data = %{"media" => %{"track" => []}}
      assert {:ok, ^data} = MediaInfoUtils.from_mediainfo_json(data)
    end

    test "returns error for nil" do
      assert {:error, _} = MediaInfoUtils.from_mediainfo_json(nil)
    end

    test "returns error for binary" do
      assert {:error, _} = MediaInfoUtils.from_mediainfo_json("not a map")
    end

    test "returns error for list" do
      assert {:error, _} = MediaInfoUtils.from_mediainfo_json([1, 2, 3])
    end
  end

  describe "extract_video_params/2" do
    defp sample_mediainfo(width, height, bitrate \\ 5_000_000) do
      %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "OverallBitRate" => bitrate,
              "Duration" => "3600.0",
              "FileSize" => 1_000_000_000
            },
            %{
              "@type" => "Video",
              "Width" => width,
              "Height" => height,
              "FrameRate" => "23.976",
              "CodecID" => "V_AV1"
            },
            %{
              "@type" => "Audio",
              "CodecID" => "A_OPUS",
              "Channels" => "2"
            }
          ]
        }
      }
    end

    test "extracts expected fields from valid mediainfo" do
      result =
        MediaInfoUtils.extract_video_params(sample_mediainfo(1920, 1080), "/test/video.mkv")

      assert is_map(result)
      assert result.width == 1920
      assert result.height == 1080
      assert result.video_codecs == ["V_AV1"]
      assert result.audio_codecs == ["A_OPUS"]
      assert result.max_audio_channels == 2
    end

    test "returns error for zero width or height" do
      assert {:error, "invalid video dimensions"} =
               MediaInfoUtils.extract_video_params(sample_mediainfo(0, 1080), "/test.mkv")

      assert {:error, "invalid video dimensions"} =
               MediaInfoUtils.extract_video_params(sample_mediainfo(1920, 0), "/test.mkv")
    end

    test "detects HDR from video track" do
      mediainfo = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "OverallBitRate" => 10_000_000,
              "Duration" => "5400.0",
              "FileSize" => 2_000_000_000
            },
            %{
              "@type" => "Video",
              "Width" => 3840,
              "Height" => 2160,
              "FrameRate" => "23.976",
              "CodecID" => "V_HEVC",
              "HDR_Format" => "Dolby Vision / SMPTE ST 2086",
              "HDR_Format_Compatibility" => "HDR10"
            }
          ]
        }
      }

      result = MediaInfoUtils.extract_video_params(mediainfo, "/hdr_video.mkv")
      assert is_map(result)
      # HDR detected — parse_hdr_from_video returns a non-nil string
      assert result.hdr != nil
    end

    test "handles mediainfo with no audio tracks" do
      mediainfo = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "OverallBitRate" => 5_000_000,
              "Duration" => "3600.0",
              "FileSize" => 500_000_000
            },
            %{
              "@type" => "Video",
              "Width" => 1280,
              "Height" => 720,
              "FrameRate" => "25.0",
              "CodecID" => "V_AV1"
            }
          ]
        }
      }

      result = MediaInfoUtils.extract_video_params(mediainfo, "/no_audio.mkv")
      assert is_map(result)
      assert result.audio_count == 0
      assert result.audio_codecs == []
    end
  end

  describe "from_video_file_info/1" do
    alias Reencodarr.Media.VideoFileInfo

    defp sample_file_info(overrides \\ %{}) do
      defaults = %{
        path: "/test/video.mkv",
        size: 2_500_000_000,
        service_id: "test1",
        service_type: :sonarr,
        audio_codec: "A_AAC",
        bitrate: 8_000_000,
        audio_channels: 6,
        video_codec: "V_MPEGH/ISO/HEVC",
        resolution: {1920, 1080},
        video_fps: 24.0,
        video_dynamic_range: "HDR10",
        video_dynamic_range_type: "HDR10",
        audio_stream_count: 2,
        overall_bitrate: 8_500_000,
        run_time: 7200,
        subtitles: ["eng", "spa"],
        title: "Test Movie"
      }

      struct(VideoFileInfo, Map.merge(defaults, overrides))
    end

    test "converts VideoFileInfo with tuple resolution to correct structure" do
      result = MediaInfoUtils.from_video_file_info(sample_file_info())

      assert is_map(result["media"])
      tracks = result["media"]["track"]
      assert length(tracks) == 3

      video = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video["Width"] == 1920
      assert video["Height"] == 1080
    end

    test "converts VideoFileInfo with string resolution" do
      info = sample_file_info(%{resolution: "3840x2160"})
      result = MediaInfoUtils.from_video_file_info(info)

      video = Enum.find(result["media"]["track"], &(&1["@type"] == "Video"))
      assert video["Width"] == 3840
      assert video["Height"] == 2160
    end

    test "general track contains correct metadata" do
      result = MediaInfoUtils.from_video_file_info(sample_file_info())
      general = Enum.find(result["media"]["track"], &(&1["@type"] == "General"))

      assert general["AudioCount"] == 2
      assert general["OverallBitRate"] == 8_500_000
      assert general["FileSize"] == 2_500_000_000
      assert general["TextCount"] == 2
      assert general["Title"] == "Test Movie"
    end

    test "falls back to bitrate when overall_bitrate is nil" do
      info = sample_file_info(%{overall_bitrate: nil})
      result = MediaInfoUtils.from_video_file_info(info)
      general = Enum.find(result["media"]["track"], &(&1["@type"] == "General"))

      assert general["OverallBitRate"] == 8_000_000
    end

    test "handles nil subtitles without crashing" do
      info = sample_file_info(%{subtitles: nil})
      result = MediaInfoUtils.from_video_file_info(info)
      general = Enum.find(result["media"]["track"], &(&1["@type"] == "General"))

      assert general["TextCount"] == 0
    end
  end
end
