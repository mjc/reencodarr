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

    test "copies audio when atmos=true" do
      video = Fixtures.create_test_video(%{atmos: true})
      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "copies eac3 because it is possibly Atmos" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["eac3"],
          mediainfo: sample_mediainfo("E-AC-3", 6, "5.1(side)")
        })

      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "copies tracks when raw CodecID shows E-AC-3 JOC despite a generic codec summary" do
      video =
        raw_audio_video(
          ["aac"],
          sample_mediainfo("Dolby Digital Plus", 6, "5.1(side)", %{
            "CodecID" => "A_EAC3/JOC",
            "Format_AdditionalFeatures" => ""
          })
        )

      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "copies tracks when raw CodecID shows TrueHD despite a generic codec summary" do
      video =
        raw_audio_video(
          ["aac"],
          sample_mediainfo("MLP FBA", 6, "5.1", %{"CodecID" => "A_TRUEHD"})
        )

      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end
  end

  describe "rules/1 - Opus transcoding" do
    test "trusted non-atmos 5.1(side) uses mapping_family 255" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1(side)")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "libopus"} in rules
      assert {"--enc", "mapping_family=255"} in rules
      refute {"--enc", "ac=6"} in rules
      refute {"--enc", "af=aformat=channel_layouts=5.1"} in rules
    end

    test "trusted non-atmos canonical 5.1 uses opus without layout coercion" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "libopus"} in rules
      refute {"--enc", "mapping_family=255"} in rules
      refute {"--enc", "ac=6"} in rules
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
              "Default" => "Yes"
            },
            audio_overrides
          )
        ]
      }
    }
  end

  defp raw_audio_video(audio_codecs, mediainfo) do
    struct(Reencodarr.Media.Video, %{
      audio_codecs: audio_codecs,
      max_audio_channels: 6,
      atmos: false,
      mediainfo: mediainfo
    })
  end
end
