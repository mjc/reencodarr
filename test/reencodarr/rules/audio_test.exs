defmodule Reencodarr.Rules.AudioTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Rules.Audio

  describe "rules/1 - Atmos and copy-through cases" do
    test "copies audio when metadata is not trustworthy enough to rule out Atmos" do
      video = Fixtures.create_test_video()
      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "copies audio with Opus codec" do
      video = Fixtures.create_opus_video()
      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "copies all audio when all tracks are Atmos" do
      video =
        raw_audio_video(
          ["truehd"],
          sample_mediainfo("Dolby TrueHD", 8, "7.1", %{
            "Format_Commercial_IfAny" => "Dolby TrueHD Atmos"
          })
        )

      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "per-stream encoding for mixed Atmos + non-Atmos tracks" do
      # Penny Dreadful style: AC3 stereo + TrueHD Atmos + AC3 stereo
      video =
        raw_audio_video(
          ["aac", "truehd", "aac"],
          mixed_atmos_mediainfo()
        )

      rules = Audio.rules(video)
      # Base is copy (preserves the Atmos track)
      assert {"--acodec", "copy"} in rules
      # Non-Atmos tracks (0 and 2) get per-stream libopus overrides
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "c:a:2=libopus"} in rules
      # The Atmos track (1) has no per-stream override, so it stays as copy
      refute {"--enc", "c:a:1=libopus"} in rules
    end

    test "transcodes eac3 to opus when there are no Atmos markers" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["eac3"],
          mediainfo: sample_mediainfo("E-AC-3", 6, "5.1(side)")
        })

      rules = Audio.rules(video)
      assert {"--acodec", "libopus"} in rules
      assert {"--enc", "af=aformat=channel_layouts=5.1|7.1|stereo"} in rules
    end

    test "copies eac3 with JOC marker in Format_AdditionalFeatures" do
      video =
        raw_audio_video(
          ["eac3"],
          sample_mediainfo("E-AC-3", 6, "5.1(side)", %{
            "Format_AdditionalFeatures" => "JOC"
          })
        )

      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "transcodes truehd to opus when there are no Atmos markers" do
      video =
        raw_audio_video(
          ["aac"],
          sample_mediainfo("MLP FBA", 6, "5.1", %{"CodecID" => "A_TRUEHD"})
        )

      rules = Audio.rules(video)
      assert {"--acodec", "libopus"} in rules
    end

    test "copies truehd with Atmos marker in format_commercial_if_any" do
      video =
        raw_audio_video(
          ["truehd"],
          sample_mediainfo("Dolby TrueHD", 6, "5.1", %{
            "Format_Commercial_IfAny" => "Dolby TrueHD Atmos"
          })
        )

      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end
  end

  describe "rules/1 - Opus transcoding" do
    test "non-atmos 5.1(side) normalizes layout with aformat filter" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1(side)")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "libopus"} in rules
      assert {"--enc", "af=aformat=channel_layouts=5.1|7.1|stereo"} in rules
      # AAC 256k * 0.8 = 205k (scaled down due to codec efficiency)
      assert {"--enc", "b:a=205k"} in rules
    end

    test "non-atmos canonical 5.1 uses opus without layout normalization" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "libopus"} in rules
      # AAC 256k * 0.8 = 205k (scaled down due to codec efficiency)
      assert {"--enc", "b:a=205k"} in rules
      refute {"--enc", "af=aformat=channel_layouts=5.1|7.1|stereo"} in rules
    end

    test "non-atmos 7.1(wide) normalizes layout with aformat filter" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 8, "7.1(wide)")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "libopus"} in rules
      assert {"--enc", "af=aformat=channel_layouts=5.1|7.1|stereo"} in rules
      # AAC 384k * 0.8 = 307k (scaled down due to codec efficiency)
      assert {"--enc", "b:a=307k"} in rules
    end

    test "unknown channel layout (nil) defaults to layout normalization" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, nil)
        })

      rules = Audio.rules(video)

      assert {"--acodec", "libopus"} in rules
      assert {"--enc", "af=aformat=channel_layouts=5.1|7.1|stereo"} in rules
    end
  end

  describe "rules/1 - edge cases" do
    test "always copies audio regardless of channels when channels=0" do
      video = Fixtures.create_test_video(%{max_audio_channels: 0})
      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "handles plain map input (non-struct)" do
      video_map = %{max_audio_channels: 2, audio_codecs: ["aac"]}
      assert Audio.rules(video_map) == [{"--acodec", "copy"}]
    end

    test "copies audio for high channel count" do
      video = Fixtures.create_test_video(%{max_audio_channels: 10})
      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "copies audio for invalid channel metadata" do
      {:ok, video} = Fixtures.video_fixture(%{max_audio_channels: nil, audio_codecs: ["aac"]})
      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end
  end

  defp sample_mediainfo(format, channels, layout, audio_overrides \\ %{}) do
    default_bitrate = default_audio_bitrate(format, channels)

    %{
      "media" => %{
        "track" => [
          %{"@type" => "General", "Duration" => "7200.0"},
          %{"@type" => "Video", "Format" => "AVC", "Width" => "1920", "Height" => "1080"},
          Map.merge(
            %{
              "@type" => "Audio",
              "Format" => format,
              "CodecID" => format,
              "Channels" => Integer.to_string(channels),
              "ChannelLayout" => layout,
              "BitRate" => default_bitrate,
              "Default" => "Yes"
            },
            audio_overrides
          )
        ]
      }
    }
  end

  defp default_audio_bitrate("AAC", 2), do: 128_000
  defp default_audio_bitrate("AAC", 6), do: 256_000
  defp default_audio_bitrate("AAC", 8), do: 384_000
  defp default_audio_bitrate("E-AC-3", 2), do: 192_000
  defp default_audio_bitrate("E-AC-3", 6), do: 384_000
  defp default_audio_bitrate("MP3", 2), do: 320_000
  defp default_audio_bitrate("Dolby TrueHD", 6), do: 3_000_000
  defp default_audio_bitrate(_, 2), do: 128_000
  defp default_audio_bitrate(_, 6), do: 384_000
  defp default_audio_bitrate(_, 8), do: 384_000
  defp default_audio_bitrate(_, _), do: 256_000

  defp raw_audio_video(audio_codecs, mediainfo) do
    struct(Reencodarr.Media.Video, %{
      audio_codecs: audio_codecs,
      max_audio_channels: 6,
      atmos: false,
      mediainfo: mediainfo
    })
  end

  # Three-track file: AC3 stereo (default) + TrueHD Atmos + AC3 stereo
  defp mixed_atmos_mediainfo do
    %{
      "media" => %{
        "track" => [
          %{"@type" => "General", "Duration" => "7200.0"},
          %{"@type" => "Video", "Format" => "AVC", "Width" => "1920", "Height" => "1080"},
          %{
            "@type" => "Audio",
            "Format" => "AC-3",
            "CodecID" => "A_AC3",
            "Channels" => "2",
            "ChannelLayout" => "L R",
            "BitRate" => 192_000,
            "Default" => "Yes"
          },
          %{
            "@type" => "Audio",
            "Format" => "MLP FBA",
            "CodecID" => "A_TRUEHD",
            "Channels" => "8",
            "ChannelLayout" => "7.1",
            "BitRate" => 3_000_000,
            "Format_Commercial_IfAny" => "Dolby TrueHD Atmos",
            "Default" => "No"
          },
          %{
            "@type" => "Audio",
            "Format" => "AC-3",
            "CodecID" => "A_AC3",
            "Channels" => "2",
            "ChannelLayout" => "L R",
            "BitRate" => 192_000,
            "Default" => "No"
          }
        ]
      }
    }
  end
end
