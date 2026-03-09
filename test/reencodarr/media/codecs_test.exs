defmodule Reencodarr.Media.CodecsTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Codecs

  describe "process_codec_list/1" do
    test "returns empty list for nil" do
      assert Codecs.process_codec_list(nil) == []
    end

    test "returns empty list for empty list" do
      assert Codecs.process_codec_list([]) == []
    end

    test "normalizes a single binary codec" do
      # normalize_codec delegates to CodecMapper.format_commercial_if_any
      # Non-Atmos strings pass through as empty string from that function
      result = Codecs.process_codec_list("Dolby Atmos")
      assert result == ["Atmos"]
    end

    test "handles non-Atmos binary — returns empty string" do
      result = Codecs.process_codec_list("H.264")
      assert result == [""]
    end

    test "handles list of codecs and deduplicates" do
      result = Codecs.process_codec_list(["Atmos", "Atmos"])
      assert result == ["Atmos"]
    end

    test "handles list with mixed atmos and other codecs" do
      result = Codecs.process_codec_list(["Dolby Atmos", "EAC3 Atmos"])
      # Both normalize to "Atmos" and then are deduplicated
      assert result == ["Atmos"]
    end
  end

  describe "map_codec_id/1" do
    test "maps AV1 to V_AV1" do
      assert Codecs.map_codec_id("AV1") == "V_AV1"
    end

    test "maps h264/x264/AVC to V_MPEG4/ISO/AVC" do
      assert Codecs.map_codec_id("h264") == "V_MPEG4/ISO/AVC"
      assert Codecs.map_codec_id("x264") == "V_MPEG4/ISO/AVC"
      assert Codecs.map_codec_id("AVC") == "V_MPEG4/ISO/AVC"
    end

    test "maps HEVC/h265/x265 to V_MPEGH/ISO/HEVC" do
      assert Codecs.map_codec_id("HEVC") == "V_MPEGH/ISO/HEVC"
      assert Codecs.map_codec_id("h265") == "V_MPEGH/ISO/HEVC"
      assert Codecs.map_codec_id("x265") == "V_MPEGH/ISO/HEVC"
    end

    test "maps Opus to A_OPUS" do
      assert Codecs.map_codec_id("Opus") == "A_OPUS"
    end

    test "maps EAC3 Atmos to :eac3_atmos atom" do
      assert Codecs.map_codec_id("EAC3 Atmos") == :eac3_atmos
    end

    test "maps TrueHD Atmos to :truehd_atmos atom" do
      assert Codecs.map_codec_id("TrueHD Atmos") == :truehd_atmos
    end

    test "returns empty string for empty string" do
      assert Codecs.map_codec_id("") == ""
    end

    test "returns empty string for nil" do
      assert Codecs.map_codec_id(nil) == ""
    end

    test "returns :unknown for unmapped codec" do
      assert Codecs.map_codec_id("WeirdNewCodec") == :unknown
    end
  end

  describe "contains_codec?/2" do
    test "returns true for matching codec (case-insensitive)" do
      # Note: H.264 does not contain the substring 'h264' (dot is literal in haystack)
      assert Codecs.contains_codec?(["H.264", "AAC"], "aac")
      assert Codecs.contains_codec?(["H.264", "AAC"], "AAC")
      assert Codecs.contains_codec?(["H.264", "AAC"], "h.264")
    end

    test "returns false for non-matching codec" do
      refute Codecs.contains_codec?(["H.264", "AAC"], "av1")
    end

    test "returns false for empty list" do
      refute Codecs.contains_codec?([], "av1")
    end

    test "partial match works" do
      assert Codecs.contains_codec?(["DTS-HD MA"], "dts")
    end
  end

  describe "has_av1_codec?/1" do
    test "returns true for V_AV1 in list" do
      assert Codecs.has_av1_codec?(["V_AV1"])
    end

    test "returns true for AV1 in list" do
      assert Codecs.has_av1_codec?(["AV1"])
    end

    test "returns false for non-AV1 list" do
      refute Codecs.has_av1_codec?(["V_MPEG4/ISO/AVC"])
    end

    test "returns false for nil" do
      refute Codecs.has_av1_codec?(nil)
    end

    test "returns false for empty list" do
      refute Codecs.has_av1_codec?([])
    end
  end

  describe "has_opus_audio?/1" do
    test "returns true when list contains opus" do
      assert Codecs.has_opus_audio?(["A_OPUS"])
      assert Codecs.has_opus_audio?(["Opus"])
    end

    test "returns false for non-opus list" do
      refute Codecs.has_opus_audio?(["A_AAC", "A_DTS"])
    end

    test "returns false for empty list" do
      refute Codecs.has_opus_audio?([])
    end
  end

  describe "hdr_content?/1" do
    test "detects HDR in codec list" do
      assert Codecs.hdr_content?(["HDR10"])
      assert Codecs.hdr_content?(["Dolby Vision"])
      assert Codecs.hdr_content?(["hdr"])
    end

    test "returns false for SDR content" do
      refute Codecs.hdr_content?(["H.264"])
      refute Codecs.hdr_content?([])
    end
  end

  describe "lossless_audio?/1" do
    test "detects FLAC" do
      assert Codecs.lossless_audio?(["FLAC"])
    end

    test "detects TrueHD" do
      assert Codecs.lossless_audio?(["TrueHD"])
    end

    test "detects DTS-HD" do
      assert Codecs.lossless_audio?(["DTS-HD MA"])
    end

    test "detects PCM" do
      assert Codecs.lossless_audio?(["PCM"])
    end

    test "returns false for lossy audio" do
      refute Codecs.lossless_audio?(["AAC", "AC3"])
      refute Codecs.lossless_audio?([])
    end
  end

  describe "primary_video_codec/1" do
    test "returns first element" do
      assert Codecs.primary_video_codec(["H.264", "H.265"]) == "H.264"
    end

    test "returns nil for empty list" do
      assert is_nil(Codecs.primary_video_codec([]))
    end
  end

  describe "map_channels/1" do
    test "maps 5.1 to 6" do
      assert Codecs.map_channels("5.1") == 6
    end

    test "maps 7.1 to 8" do
      assert Codecs.map_channels("7.1") == 8
    end

    test "maps 2 to 2" do
      assert Codecs.map_channels("2") == 2
    end

    test "maps stereo integer" do
      assert Codecs.map_channels(2) == 2
    end

    test "returns 0 for unknown channel string" do
      assert Codecs.map_channels("xyz") == 0
    end

    test "returns 0 for empty string" do
      assert Codecs.map_channels("") == 0
    end

    test "maps mono 1 to 1" do
      assert Codecs.map_channels("1") == 1
    end
  end

  describe "map_channels_with_context/2" do
    test "maps non-5 channels normally" do
      assert Codecs.map_channels_with_context("7.1") == 8
      assert Codecs.map_channels_with_context("2") == 2
    end

    test "maps 5 channels to 5 for PCM codec" do
      result = Codecs.map_channels_with_context("5", %{"Format" => "PCM"})
      assert result == 5
    end

    test "maps 5 channels to 6 for DTS surround codec" do
      result = Codecs.map_channels_with_context("5", %{"Format" => "DTS"})
      assert result == 6
    end

    test "maps 5 channels to 6 for AC3 codec" do
      result = Codecs.map_channels_with_context("5", %{"audioCodec" => "AC3"})
      assert result == 6
    end
  end

  describe "normalize_codec/1" do
    test "normalizes Atmos-containing string to Atmos" do
      assert Codecs.normalize_codec("Dolby Atmos") == "Atmos"
    end

    test "normalizes EAC3 Atmos to Atmos" do
      assert Codecs.normalize_codec("EAC3 Atmos") == "Atmos"
    end

    test "returns empty string for non-Atmos codec" do
      assert Codecs.normalize_codec("AAC") == ""
    end

    test "returns empty string for unknown codec" do
      assert Codecs.normalize_codec("SomeRandomCodec") == ""
    end
  end

  describe "has_opus_audio_in_mediainfo?/1" do
    test "returns false when tracks are nil" do
      refute Codecs.has_opus_audio_in_mediainfo?(%{"media" => %{"track" => nil}})
    end

    test "returns false for empty mediainfo map" do
      refute Codecs.has_opus_audio_in_mediainfo?(%{})
    end

    test "returns true when audio track list contains Opus by Format" do
      mediainfo = %{
        "media" => %{
          "track" => [
            %{"@type" => "Video", "CodecID" => "V_AV1"},
            %{"@type" => "Audio", "Format" => "Opus"}
          ]
        }
      }

      assert Codecs.has_opus_audio_in_mediainfo?(mediainfo)
    end

    test "returns true when audio track list contains Opus by CodecID" do
      mediainfo = %{
        "media" => %{
          "track" => [
            %{"@type" => "Audio", "CodecID" => "A_OPUS"}
          ]
        }
      }

      assert Codecs.has_opus_audio_in_mediainfo?(mediainfo)
    end

    test "returns false when audio tracks have no Opus" do
      mediainfo = %{
        "media" => %{
          "track" => [
            %{"@type" => "Audio", "Format" => "AAC", "CodecID" => "A_AAC"}
          ]
        }
      }

      refute Codecs.has_opus_audio_in_mediainfo?(mediainfo)
    end

    test "returns true for single Opus audio track map" do
      mediainfo = %{
        "media" => %{
          "track" => %{"@type" => "Audio", "Format" => "Opus"}
        }
      }

      assert Codecs.has_opus_audio_in_mediainfo?(mediainfo)
    end

    test "returns false for single non-Opus track map" do
      mediainfo = %{
        "media" => %{
          "track" => %{"@type" => "Audio", "Format" => "AAC"}
        }
      }

      refute Codecs.has_opus_audio_in_mediainfo?(mediainfo)
    end
  end

  describe "video_codecs_only/1" do
    test "filters mixed list to video codecs only" do
      result = Codecs.video_codecs_only(["HEVC", "AAC", "AV1", "FLAC"])
      assert "HEVC" in result
      assert "AV1" in result
      refute "AAC" in result
      refute "FLAC" in result
    end

    test "returns empty list when all codecs are audio" do
      assert Codecs.video_codecs_only(["AAC", "AC3", "Opus"]) == []
    end

    test "returns all codecs when all are video" do
      result = Codecs.video_codecs_only(["HEVC", "VP9", "AV1"])
      assert length(result) == 3
    end

    test "returns empty list for empty input" do
      assert Codecs.video_codecs_only([]) == []
    end
  end

  describe "audio_codecs_only/1" do
    test "filters mixed list to audio codecs only" do
      result = Codecs.audio_codecs_only(["HEVC", "AAC", "AV1", "FLAC"])
      assert "AAC" in result
      assert "FLAC" in result
      refute "HEVC" in result
      refute "AV1" in result
    end

    test "returns empty list when all codecs are video" do
      assert Codecs.audio_codecs_only(["HEVC", "VP9", "AV1"]) == []
    end

    test "returns all codecs when all are audio" do
      result = Codecs.audio_codecs_only(["AAC", "AC3", "Opus", "FLAC"])
      assert length(result) == 4
    end

    test "returns empty list for empty input" do
      assert Codecs.audio_codecs_only([]) == []
    end
  end
end
