defmodule Reencodarr.Encoder.AudioArgsTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Rules

  describe "centralized argument building" do
    setup do
      # Create a test video struct without database persistence
      alias Reencodarr.Media.Video

      video = %Video{
        id: 1,
        path: "/test/sample_video.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
        # Non-Opus, so should include audio args
        audio_codecs: ["aac"],
        state: :needs_analysis,
        width: 1920,
        height: 1080,
        frame_rate: 23.976,
        duration: 7200.0,
        max_audio_channels: 6,
        atmos: false,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

      %{video: video}
    end

    test "Rules.build_args for encoding includes audio arguments", %{video: video} do
      args = Rules.build_args(video, :encode)

      # Should include audio codec
      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "libopus"

      # Should include audio bitrate
      enc_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--enc" end)
        |> Enum.map(&elem(&1, 1))

      bitrate_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "b:a=")
        end)

      assert bitrate_found, "Should include audio bitrate argument"

      # Should include audio channels
      channels_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "ac=")
        end)

      assert channels_found, "Should include audio channels argument"
    end

    test "Rules.build_args for CRF search excludes audio arguments", %{video: video} do
      args = Rules.build_args(video, :crf_search)

      # Should NOT include audio codec
      refute "--acodec" in args

      # Should NOT include audio enc arguments
      enc_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--enc" end)
        |> Enum.map(&elem(&1, 1))

      audio_enc_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "b:a=") or String.contains?(value, "ac=")
        end)

      refute audio_enc_found, "CRF search should not include audio arguments"
    end

    test "handles Opus audio codec correctly" do
      alias Reencodarr.Media.Video

      opus_video = %Video{
        id: 2,
        path: "/test/opus_video.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
        # Already Opus
        audio_codecs: ["A_OPUS"],
        state: :needs_analysis,
        width: 1920,
        height: 1080,
        frame_rate: 23.976,
        duration: 7200.0,
        max_audio_channels: 6,
        atmos: false,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

      args = Rules.build_args(opus_video, :encode)

      # Should NOT include audio codec args since it's already Opus
      refute "--acodec" in args

      # Should still include video args
      assert length(args) > 0
    end
  end

  describe "audio channel handling" do
    test "handles different channel configurations" do
      alias Reencodarr.Media.Video

      stereo_video = %Video{
        id: 3,
        path: "/test/stereo.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        # Stereo
        max_audio_channels: 2,
        atmos: false,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

      args = Rules.build_args(stereo_video, :encode)

      # Should include arguments appropriate for stereo
      assert is_list(args)
      assert length(args) > 0
    end

    test "handles Atmos audio correctly" do
      alias Reencodarr.Media.Video

      atmos_video = %Video{
        id: 4,
        path: "/test/atmos.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
        audio_codecs: ["truehd"],
        max_audio_channels: 8,
        # Atmos content
        atmos: true,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

      args = Rules.build_args(atmos_video, :encode)

      # Should handle Atmos appropriately
      assert is_list(args)
      assert length(args) > 0
    end
  end
end
