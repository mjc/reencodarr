defmodule Reencodarr.Analyzer.Broadway.CodecDetectionTest do
  use Reencodarr.DataCase, async: true

  @moduletag :unit

  alias Reencodarr.Analyzer.Broadway

  describe "codec detection helpers" do
    test "has_av1_codec? detects AV1 codec correctly" do
      # Test with V_AV1 (MediaInfo format)
      video_v_av1 = %Reencodarr.Media.Video{
        video_codecs: ["V_AV1"],
        audio_codecs: ["A_AAC"]
      }

      assert Broadway.has_av1_codec?(video_v_av1) == true

      # Test with AV1 (standard format)
      video_av1 = %Reencodarr.Media.Video{
        video_codecs: ["AV1"],
        audio_codecs: ["A_AAC"]
      }

      assert Broadway.has_av1_codec?(video_av1) == true

      # Test with H.264 (no AV1)
      video_h264 = %Reencodarr.Media.Video{
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: ["A_AAC"]
      }

      assert Broadway.has_av1_codec?(video_h264) == false

      # Test with nil video_codecs
      video_nil = %Reencodarr.Media.Video{
        video_codecs: nil,
        audio_codecs: ["A_AAC"]
      }

      assert Broadway.has_av1_codec?(video_nil) == false

      # Test with empty video_codecs
      video_empty = %Reencodarr.Media.Video{
        video_codecs: [],
        audio_codecs: ["A_AAC"]
      }

      assert Broadway.has_av1_codec?(video_empty) == false
    end

    test "has_opus_codec? detects Opus audio correctly" do
      # Test with A_OPUS (MediaInfo format)
      video_opus = %Reencodarr.Media.Video{
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: ["A_OPUS"]
      }

      assert Broadway.has_opus_codec?(video_opus) == true

      # Test with Opus (standard format)
      video_opus_std = %Reencodarr.Media.Video{
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: ["Opus"]
      }

      assert Broadway.has_opus_codec?(video_opus_std) == true

      # Test with AAC (no Opus)
      video_aac = %Reencodarr.Media.Video{
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: ["A_AAC"]
      }

      assert Broadway.has_opus_codec?(video_aac) == false

      # Test with nil audio_codecs
      video_nil = %Reencodarr.Media.Video{
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: nil
      }

      assert Broadway.has_opus_codec?(video_nil) == false

      # Test with empty audio_codecs
      video_empty = %Reencodarr.Media.Video{
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: []
      }

      assert Broadway.has_opus_codec?(video_empty) == false
    end

    test "transition_video_to_analyzed skips CRF search for AV1 videos" do
      # Create a video with AV1 codec
      video = %Reencodarr.Media.Video{
        id: 1,
        path: "/test/video.mkv",
        video_codecs: ["V_AV1"],
        audio_codecs: ["A_AAC"],
        state: :needs_analysis
      }

      # Test the pure business logic function
      decision = Broadway.determine_video_transition_decision(video)
      assert decision == {:encoded, "already has AV1 codec"}
    end

    test "transition_video_to_analyzed skips CRF search for Opus videos" do
      # Create a video with Opus audio
      video = %Reencodarr.Media.Video{
        id: 2,
        path: "/test/video.mkv",
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: ["A_OPUS"],
        state: :needs_analysis
      }

      # Test the pure business logic function
      decision = Broadway.determine_video_transition_decision(video)
      assert decision == {:encoded, "already has Opus audio codec"}
    end

    test "transition_video_to_analyzed continues to analyzed state for videos needing CRF search" do
      # Create a video that needs CRF search (H.264 + AAC)
      video = %Reencodarr.Media.Video{
        id: 3,
        path: "/test/video.mkv",
        video_codecs: ["V_MPEG4/ISO/AVC"],
        audio_codecs: ["A_AAC"],
        state: :needs_analysis
      }

      # Test the pure business logic function
      decision = Broadway.determine_video_transition_decision(video)
      assert decision == {:analyzed, "needs CRF search"}
    end

    test "regression test for video 2254 bug - AV1/Opus videos should not be queued for encoding" do
      # Test the exact scenario that caused video 2254 to be incorrectly processed
      av1_opus_video = %Reencodarr.Media.Video{
        id: 2254,
        path: "/media/av1_opus_video.mkv",
        video_codecs: ["V_AV1"],
        audio_codecs: ["A_OPUS"],
        state: :needs_analysis
      }

      # Both codec checks should return true
      assert Broadway.has_av1_codec?(av1_opus_video) == true
      assert Broadway.has_opus_codec?(av1_opus_video) == true

      # Test the pure business logic - should decide to encode (skip processing)
      # Since has_av1_codec? returns true first, it should be encoded with AV1 reason
      decision = Broadway.determine_video_transition_decision(av1_opus_video)
      assert decision == {:encoded, "already has AV1 codec"}
    end
  end
end
