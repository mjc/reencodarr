defmodule Reencodarr.Media.CodecMapperTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.CodecMapper

  describe "map_codec_id/1" do
    test "maps AV1 to V_AV1" do
      assert CodecMapper.map_codec_id("AV1") == "V_AV1"
    end

    test "maps h264/x264/AVC to V_MPEG4/ISO/AVC" do
      assert CodecMapper.map_codec_id("h264") == "V_MPEG4/ISO/AVC"
      assert CodecMapper.map_codec_id("x264") == "V_MPEG4/ISO/AVC"
      assert CodecMapper.map_codec_id("AVC") == "V_MPEG4/ISO/AVC"
    end

    test "maps HEVC/h265/x265 to V_MPEGH/ISO/HEVC" do
      assert CodecMapper.map_codec_id("HEVC") == "V_MPEGH/ISO/HEVC"
      assert CodecMapper.map_codec_id("h265") == "V_MPEGH/ISO/HEVC"
      assert CodecMapper.map_codec_id("x265") == "V_MPEGH/ISO/HEVC"
    end

    test "maps audio codecs" do
      assert CodecMapper.map_codec_id("Opus") == "A_OPUS"
      assert CodecMapper.map_codec_id("AAC") == "A_AAC"
      assert CodecMapper.map_codec_id("AC3") == "A_AC3"
      assert CodecMapper.map_codec_id("EAC3") == "A_EAC3"
      assert CodecMapper.map_codec_id("TrueHD") == "A_TRUEHD"
      assert CodecMapper.map_codec_id("DTS") == "A_DTS"
      assert CodecMapper.map_codec_id("FLAC") == "A_FLAC"
    end

    test "maps Atmos variants to atoms" do
      assert CodecMapper.map_codec_id("EAC3 Atmos") == :eac3_atmos
      assert CodecMapper.map_codec_id("TrueHD Atmos") == :truehd_atmos
    end

    test "maps empty string to empty string" do
      assert CodecMapper.map_codec_id("") == ""
    end

    test "maps nil to empty string" do
      assert CodecMapper.map_codec_id(nil) == ""
    end

    test "returns :unknown for unrecognized codec" do
      assert CodecMapper.map_codec_id("SomeWeirdCodec") == :unknown
    end
  end

  describe "has_av1_codec?/1" do
    test "returns true for V_AV1" do
      assert CodecMapper.has_av1_codec?(["V_AV1"])
    end

    test "returns true for AV1" do
      assert CodecMapper.has_av1_codec?(["AV1"])
    end

    test "returns false for non-AV1" do
      refute CodecMapper.has_av1_codec?(["V_MPEG4/ISO/AVC"])
    end

    test "returns false for nil" do
      refute CodecMapper.has_av1_codec?(nil)
    end

    test "returns false for empty list" do
      refute CodecMapper.has_av1_codec?([])
    end
  end

  describe "has_opus_audio?/1" do
    test "detects Opus via Format field" do
      mediainfo = %{
        "media" => %{
          "track" => [
            %{"@type" => "General"},
            %{"@type" => "Audio", "Format" => "Opus"}
          ]
        }
      }

      assert CodecMapper.has_opus_audio?(mediainfo)
    end

    test "detects Opus via CodecID field" do
      mediainfo = %{
        "media" => %{
          "track" => [%{"@type" => "Audio", "CodecID" => "A_OPUS"}]
        }
      }

      assert CodecMapper.has_opus_audio?(mediainfo)
    end

    test "returns false when no audio tracks" do
      mediainfo = %{"media" => %{"track" => [%{"@type" => "General"}]}}
      refute CodecMapper.has_opus_audio?(mediainfo)
    end

    test "returns false when track is nil" do
      refute CodecMapper.has_opus_audio?(%{"media" => %{"track" => nil}})
    end

    test "returns false for non-opus audio" do
      mediainfo = %{
        "media" => %{
          "track" => [%{"@type" => "Audio", "Format" => "AAC"}]
        }
      }

      refute CodecMapper.has_opus_audio?(mediainfo)
    end
  end

  describe "audio_track_is_opus?/1" do
    test "returns true for Audio track with Format Opus" do
      assert CodecMapper.audio_track_is_opus?(%{"@type" => "Audio", "Format" => "Opus"})
    end

    test "returns true for Audio track with CodecID A_OPUS" do
      assert CodecMapper.audio_track_is_opus?(%{"@type" => "Audio", "CodecID" => "A_OPUS"})
    end

    test "returns false for non-audio track" do
      refute CodecMapper.audio_track_is_opus?(%{"@type" => "Video", "Format" => "Opus"})
    end

    test "returns false for AAC audio" do
      refute CodecMapper.audio_track_is_opus?(%{"@type" => "Audio", "Format" => "AAC"})
    end

    test "returns false for empty map" do
      refute CodecMapper.audio_track_is_opus?(%{})
    end
  end

  describe "map_channels/1" do
    test "maps common surround layouts" do
      assert CodecMapper.map_channels("5.1") == 6
      assert CodecMapper.map_channels("7.1") == 8
      assert CodecMapper.map_channels("2") == 2
      assert CodecMapper.map_channels("1") == 1
    end

    test "accepts integer input" do
      assert CodecMapper.map_channels(2) == 2
    end

    test "accepts float input" do
      assert CodecMapper.map_channels(5.1) == 6
    end

    test "returns 0 for unparseable input" do
      assert CodecMapper.map_channels("unknown") == 0
    end

    test "maps 0 to 0" do
      assert CodecMapper.map_channels("0") == 0
    end
  end

  describe "map_channels_with_context/2" do
    test "returns 5 for 5 channels with neutral codec" do
      assert CodecMapper.map_channels_with_context("5") == 5
    end

    test "returns 6 for 5 channels with DTS codec (assumed 5.1)" do
      assert CodecMapper.map_channels_with_context("5", %{"Format" => "DTS"}) == 6
    end

    test "returns 6 for 5 channels with AC3 codec" do
      assert CodecMapper.map_channels_with_context("5", %{"audioCodec" => "AC3"}) == 6
    end

    test "returns 6 for 5 channels with Atmos commercial format" do
      assert CodecMapper.map_channels_with_context("5", %{
               "Format_Commercial_IfAny" => "Dolby Atmos"
             }) == 6
    end

    test "delegates non-5 channels to map_channels" do
      assert CodecMapper.map_channels_with_context("7.1") == 8
      assert CodecMapper.map_channels_with_context("2") == 2
    end
  end

  describe "format_commercial_if_any/1" do
    test "detects Dolby Atmos" do
      assert CodecMapper.format_commercial_if_any("Dolby Atmos") == "Atmos"
    end

    test "detects DTS:X as Atmos" do
      assert CodecMapper.format_commercial_if_any("DTS:X") == "Atmos"
    end

    test "detects TrueHD Atmos" do
      assert CodecMapper.format_commercial_if_any("TrueHD Atmos") == "Atmos"
    end

    test "detects EAC3 Atmos" do
      assert CodecMapper.format_commercial_if_any("EAC3 Atmos") == "Atmos"
    end

    test "returns empty string for non-Atmos formats" do
      assert CodecMapper.format_commercial_if_any("DTS-HD MA") == ""
      assert CodecMapper.format_commercial_if_any("AAC") == ""
    end

    test "returns empty string for nil" do
      assert CodecMapper.format_commercial_if_any(nil) == ""
    end

    test "handles Atmos atom values" do
      assert CodecMapper.format_commercial_if_any(:eac3_atmos) == "Atmos"
      assert CodecMapper.format_commercial_if_any(:truehd_atmos) == "Atmos"
    end

    test "is case-insensitive for ATMOS" do
      assert CodecMapper.format_commercial_if_any("DOLBY ATMOS") == "Atmos"
    end
  end
end
