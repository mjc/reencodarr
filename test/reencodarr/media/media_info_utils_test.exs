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
end
