defmodule Reencodarr.Encoder.AudioArgsTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Rules

  describe "centralized argument building" do
    setup do
      alias Reencodarr.Media.Video

      video = %Video{
        id: 1,
        path: "/test/sample_video.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
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

    test "Rules.build_args for encoding copies audio", %{video: video} do
      args = Rules.build_args(video, :encode)

      # Should include audio codec set to copy
      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "copy"

      # Should NOT include any audio encoding enc arguments
      enc_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--enc" end)
        |> Enum.map(&elem(&1, 1))

      audio_enc_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "b:a=") or String.contains?(value, "ac=")
        end)

      refute audio_enc_found, "Should not include audio encoding arguments"
    end

    test "Rules.build_args for CRF search excludes audio arguments", %{video: video} do
      args = Rules.build_args(video, :crf_search)

      # Should NOT include audio codec
      refute "--acodec" in args
    end

    test "handles Opus audio codec - still copies", %{video: _video} do
      alias Reencodarr.Media.Video

      opus_video = %Video{
        id: 2,
        path: "/test/opus_video.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
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

      # Should include audio codec set to copy
      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "copy"
    end
  end

  describe "audio channel handling" do
    test "all channel configurations just copy audio" do
      alias Reencodarr.Media.Video

      stereo_video = %Video{
        id: 3,
        path: "/test/stereo.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        max_audio_channels: 2,
        atmos: false,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

      args = Rules.build_args(stereo_video, :encode)

      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "copy"
    end

    test "handles Atmos audio - still copies" do
      alias Reencodarr.Media.Video

      atmos_video = %Video{
        id: 4,
        path: "/test/atmos.mkv",
        bitrate: 8_000_000,
        size: 3_000_000_000,
        video_codecs: ["h264"],
        audio_codecs: ["truehd"],
        max_audio_channels: 8,
        atmos: true,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

      args = Rules.build_args(atmos_video, :encode)

      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "copy"
    end
  end
end
