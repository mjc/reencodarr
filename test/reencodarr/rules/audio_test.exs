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

    test "transcodes non-Opus tracks when another track is already Opus" do
      video =
        raw_audio_video(
          ["opus", "aac"],
          multi_track_mediainfo([
            {"Opus", 2, "L R", 128_000},
            {"AAC", 2, "L R", 128_000}
          ])
        )

      rules = Audio.rules(video)

      refute {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "c:a:1=libopus"} in rules
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
      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
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
      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "b:a:0=256k"} in rules
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

    test "copies DTS:X while transcoding the other tracks" do
      video =
        raw_audio_video(
          ["dts", "aac"],
          multi_track_mediainfo([
            {"DTS", 6, "5.1", 768_000, %{"Format_Commercial_IfAny" => "DTS:X"}},
            {"AAC", 2, "L R", 128_000}
          ])
        )

      rules = Audio.rules(video)

      refute {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "c:a:1=libopus"} in rules
    end
  end

  describe "rules/1 - Opus transcoding" do
    test "uses the channel target when an ordinary track has no bitrate" do
      video =
        raw_audio_video(
          ["dts"],
          sample_mediainfo("DTS", 6, "5.1", %{
            "CodecID" => "A_DTS",
            "Format_Commercial_IfAny" => "DTS-HD Master Audio",
            "Format_AdditionalFeatures" => "XLL",
            "BitRate" => nil
          })
        )

      rules = Audio.rules(video)

      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "b:a:0=256k"} in rules
    end

    test "uses the channel target for common non-object codecs with no bitrate" do
      for {format, codec_id} <- [
            {"AAC", "A_AAC"},
            {"AC-3", "A_AC3"},
            {"E-AC-3", "A_EAC3"},
            {"DTS", "A_DTS"},
            {"FLAC", "A_FLAC"},
            {"PCM", "A_PCM/INT/LIT"}
          ] do
        video =
          raw_audio_video(
            [format],
            sample_mediainfo(format, 6, "5.1", %{"CodecID" => codec_id, "BitRate" => nil})
          )

        assert {"--enc", "b:a:0=256k"} in Audio.rules(video)
      end
    end

    test "classifies every codec identity captured from the production encode queue" do
      for %{"format" => format, "codec_id" => codec_id} <- production_queue_tracks() do
        video =
          raw_audio_video(
            [format],
            sample_mediainfo(format, 6, "5.1", %{
              "CodecID" => codec_id,
              "BitRate" => nil
            })
          )

        rules = Audio.rules(video)

        if format == "Opus" do
          assert rules == [{"--acodec", "copy"}]
        else
          assert {"--enc", "c:a:0=libopus"} in rules
          assert {"--enc", "b:a:0=256k"} in rules
        end
      end
    end

    test "transcodes supported ISO-BMFF carrier short codes" do
      for {format, codec_id} <- [
            {"AAC", "mp4a-40-5"},
            {"MLP FBA", "mlpa"},
            {"DTS", "dtsh"},
            {"DTS", "dtsl"},
            {"PCM", "ipcm"}
          ] do
        video =
          raw_audio_video(
            [format],
            sample_mediainfo(format, 6, "5.1", %{"CodecID" => codec_id, "BitRate" => nil})
          )

        assert {"--enc", "c:a:0=libopus"} in Audio.rules(video)
      end
    end

    test "non-atmos 5.1(side) normalizes layout with aformat filter" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1(side)")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
      # AAC 256k * 0.8 = 205k (scaled down due to codec efficiency)
      assert {"--enc", "b:a:0=205k"} in rules
    end

    test "non-atmos canonical 5.1 uses opus without layout normalization" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      # AAC 256k * 0.8 = 205k (scaled down due to codec efficiency)
      assert {"--enc", "b:a:0=205k"} in rules
      refute {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
    end

    test "non-atmos 7.1(wide) normalizes layout with aformat filter" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 8, "7.1(wide)")
        })

      rules = Audio.rules(video)

      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
      # AAC 384k * 0.8 = 307k (scaled down due to codec efficiency)
      assert {"--enc", "b:a:0=307k"} in rules
    end

    test "unknown channel layout (nil) defaults to layout normalization" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, nil)
        })

      rules = Audio.rules(video)

      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
    end
  end

  describe "rules/1 - object audio classification" do
    test "copies DTS:X identified only by the XLL X extension" do
      video =
        raw_audio_video(
          ["dts"],
          sample_mediainfo("DTS", 8, "7.1", %{
            "CodecID" => "A_DTS/LOSSLESS",
            "Format_AdditionalFeatures" => "XLL X"
          })
        )

      assert Audio.rules(video) == [{"--acodec", "copy"}]
    end

    test "copies object carriers captured from production MediaInfo" do
      for %{"track" => track} <- production_object_tracks() do
        video = raw_audio_video([], mediainfo_with_audio_track(track))
        assert Audio.rules(video) == [{"--acodec", "copy"}]
      end
    end

    test "copies object metadata on supported ISO-BMFF carriers" do
      for {format, codec_id, commercial, additional} <- [
            {"MLP FBA", "mlpa", "Dolby TrueHD with Dolby Atmos", ""},
            {"DTS", "dtsh", "DTS-HD MA + DTS:X", "XLL X"},
            {"DTS", "dtsl", "DTS:X", ""}
          ] do
        video =
          raw_audio_video(
            [format],
            sample_mediainfo(format, 8, "7.1", %{
              "CodecID" => codec_id,
              "Format_Commercial_IfAny" => commercial,
              "Format_AdditionalFeatures" => additional
            })
          )

        assert Audio.rules(video) == [{"--acodec", "copy"}]
      end
    end

    test "does not treat object branding as proof on the wrong carrier" do
      for commercial <- ["Dolby Atmos", "DTS:X", "Apple Spatial Audio"] do
        video =
          raw_audio_video(
            ["aac"],
            sample_mediainfo("AAC", 6, "5.1", %{
              "CodecID" => "A_AAC-2",
              "Format_Commercial_IfAny" => commercial
            })
          )

        assert {"--enc", "c:a:0=libopus"} in Audio.rules(video)
      end
    end

    test "transcodes plain AC-4 but rejects immersive AC-4 before encode" do
      plain = raw_audio_video(["ac4"], sample_mediainfo("AC-4", 6, "5.1"))

      immersive =
        raw_audio_video(
          ["ac4"],
          sample_mediainfo("AC-4", 6, "5.1", %{
            "Format_Profile" => "IMS Atmos"
          })
        )

      assert {"--enc", "c:a:0=libopus"} in Audio.rules(plain)
      assert_raise Audio.ClassificationError, ~r/AC-4/, fn -> Audio.rules(immersive) end
    end

    test "rejects registered object-audio identities without Matroska carriage" do
      for {format, codec_id} <- [
            {"DTS", "dtsx"},
            {"DTS", "dtsy"},
            {"DTS-UHD MA", "A_DTS"},
            {"MPEG-H 3D Audio", "mha1"},
            {"MPEG-H 3D Audio", "mha2"},
            {"MPEG-H 3D Audio", "mhm1"},
            {"MPEG-H 3D Audio", "mhm2"},
            {"IAMF", "iamf"},
            {"Apple Positional Audio Codec", "apac"},
            {"Auro-Cx", "a3ds"},
            {"AuroMax", "a3ds"},
            {"IAB", ""}
          ] do
        video =
          raw_audio_video(
            [format],
            sample_mediainfo(format, 6, "5.1", %{"CodecID" => codec_id})
          )

        assert_raise Audio.ClassificationError, fn -> Audio.rules(video) end
      end
    end

    test "rejects IAMF even when its inner codec makes audio_codecs look like Opus" do
      video =
        raw_audio_video(
          ["opus"],
          sample_mediainfo("IAMF", 6, "5.1", %{"CodecID" => "iamf"})
        )

      assert_raise Audio.ClassificationError, ~r/IAMF/, fn -> Audio.rules(video) end
    end

    test "uses the IAMF container identity instead of treating inner Opus as standalone" do
      mediainfo =
        sample_mediainfo("Opus", 6, "5.1", %{
          "CodecID" => "A_OPUS",
          "Format_Commercial_IfAny" => "Eclipsa Audio"
        })
        |> put_in(["media", "track", Access.at(0), "Format"], "IAMF")

      video =
        raw_audio_video(["opus"], mediainfo)

      assert_raise Audio.ClassificationError, ~r/IAMF container/, fn -> Audio.rules(video) end
    end

    test "rejects MPEG-I identity carried by MPEG-H" do
      video =
        raw_audio_video(
          ["mpegh"],
          sample_mediainfo("MPEG-H 3D Audio", 6, "5.1", %{
            "CodecID" => "mhm1",
            "Format_Profile" => "MPEG-I Immersive Audio"
          })
        )

      assert_raise Audio.ClassificationError, fn -> Audio.rules(video) end
    end

    test "uses the APAC sample entry without confusing Marian A-pac with Apple audio" do
      apple =
        raw_audio_video(
          ["apac"],
          sample_mediainfo("Apple Positional Audio Codec", 6, "5.1", %{"CodecID" => "apac"})
        )

      marian =
        raw_audio_video(
          ["apac"],
          sample_mediainfo("A-pac", 2, "L R", %{"CodecID" => ""})
        )

      apple_error = assert_raise Audio.ClassificationError, fn -> Audio.rules(apple) end
      marian_error = assert_raise Audio.ClassificationError, fn -> Audio.rules(marian) end

      assert apple_error.reason == "unknown audio identity"
      assert marian_error.reason == "unknown audio identity"
    end

    test "rejects ADM in BW64 instead of flattening its PCM carrier" do
      mediainfo =
        sample_mediainfo("PCM", 8, "7.1", %{"CodecID" => "A_PCM/INT/LIT"})
        |> put_in(["media", "track", Access.at(0), "Format"], "BW64")

      assert_raise Audio.ClassificationError, ~r/ADM/, fn ->
        Audio.rules(raw_audio_video(["pcm"], mediainfo))
      end
    end

    test "does not treat channel-based Auro-3D as Auro-Cx" do
      video =
        raw_audio_video(
          ["pcm"],
          sample_mediainfo("PCM", 6, "5.1", %{
            "CodecID" => "A_PCM/INT/LIT",
            "Format_Commercial_IfAny" => "Auro-3D"
          })
        )

      assert {"--enc", "c:a:0=libopus"} in Audio.rules(video)
    end

    test "fails explicitly when an audio track cannot be classified" do
      video =
        raw_audio_video(
          ["unknown"],
          sample_mediainfo("", 6, "5.1", %{"CodecID" => "", "BitRate" => nil})
        )

      assert_raise Audio.ClassificationError, ~r/audio track 0/, fn -> Audio.rules(video) end
    end

    test "does not accept an unknown identity merely because its name contains AAC" do
      video =
        raw_audio_video(
          ["unknown"],
          sample_mediainfo("Not AAC", 2, "L R", %{"CodecID" => "unknown"})
        )

      assert_raise Audio.ClassificationError, ~r/unknown audio identity/, fn ->
        Audio.rules(video)
      end
    end

    test "rejects an unknown sample entry even when the carrier format is ordinary" do
      video =
        raw_audio_video(
          ["dts"],
          sample_mediainfo("DTS", 6, "5.1", %{"CodecID" => "future-object-audio"})
        )

      assert_raise Audio.ClassificationError, ~r/unknown audio identity/, fn ->
        Audio.rules(video)
      end
    end
  end

  describe "rules/1 - multi-track files with mixed layouts" do
    test "per-stream rules for file with 5.1 + 2.0 stereo (no Atmos)" do
      # Common case: 5.1 surround + 2.0 stereo descriptive audio
      video =
        raw_audio_video(
          ["aac", "aac"],
          multi_track_mediainfo([
            {"AAC", 6, "5.1", 256_000},
            {"AAC", 2, "L R", 128_000}
          ])
        )

      rules = Audio.rules(video)

      # Base is copy (so all tracks are mapped)
      assert {"--acodec", "copy"} in rules
      # Track 0 (5.1): encode to opus with 256k and normalization
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "b:a:0=205k"} in rules
      assert {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} not in rules

      # Track 1 (2.0): encode to opus with 128k, no filter needed
      assert {"--enc", "c:a:1=libopus"} in rules
      assert {"--enc", "b:a:1=102k"} in rules
    end

    test "per-stream rules for file with 5.1(side) + 2.0 + unsupported layout" do
      # File with problematic 5.1(side) on track 1 and 2.0 on track 0
      video =
        raw_audio_video(
          ["aac", "aac", "aac"],
          multi_track_mediainfo([
            {"AAC", 2, "L R", 128_000},
            {"AAC", 6, "5.1(side)", 384_000},
            {"AC-3", 6, "5.1", 384_000}
          ])
        )

      rules = Audio.rules(video)

      # Base is copy
      assert {"--acodec", "copy"} in rules
      # Track 0 (2.0 stereo): encode to opus
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "b:a:0=102k"} in rules

      # Track 1 (5.1(side)): encode to opus with normalization filter
      assert {"--enc", "c:a:1=libopus"} in rules
      assert {"--enc", "filter:a:1=aformat=channel_layouts=5.1|7.1|stereo"} in rules

      # Track 2 (AC-3 5.1): encode to opus
      assert {"--enc", "c:a:2=libopus"} in rules
    end

    test "invalid codec-channel metadata fails instead of copying one track" do
      # Track 0: valid (AAC stereo)
      # Track 1: invalid (MP3 5.1 - mp3 doesn't support > 2 channels)
      # Track 2: valid (AAC 5.1)
      video =
        raw_audio_video(
          ["aac", "mp3", "aac"],
          multi_track_mediainfo([
            {"AAC", 2, "L R", 128_000},
            {"MP3", 6, "5.1", 320_000},
            {"AAC", 6, "5.1", 256_000}
          ])
        )

      assert_raise Audio.ClassificationError, ~r/MP3/, fn -> Audio.rules(video) end
    end

    test "tracks with missing channel metadata fail instead of copying" do
      # Tracks with no channel info - can't determine encoding
      video =
        raw_audio_video(
          ["aac", "aac"],
          %{
            "media" => %{
              "track" => [
                %{"@type" => "General", "Duration" => "7200.0"},
                %{"@type" => "Video", "Format" => "AVC", "Width" => "1920", "Height" => "1080"},
                %{"@type" => "Audio", "Format" => "AAC"},
                %{"@type" => "Audio", "Format" => "AAC"}
              ]
            }
          }
        )

      assert_raise Audio.ClassificationError, ~r/channel count/, fn -> Audio.rules(video) end
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

    test "classifies per-track metadata when the aggregate channel count is missing" do
      video =
        raw_audio_video(["aac"], sample_mediainfo("AAC", 2, "L R"))
        |> Map.put(:max_audio_channels, nil)

      assert {"--enc", "c:a:0=libopus"} in Audio.rules(video)
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

  defp production_object_tracks do
    path = Path.expand("../../fixtures/mediainfo_object_audio_production.json", __DIR__)
    path |> File.read!() |> Jason.decode!()
  end

  defp production_queue_tracks do
    path = Path.expand("../../fixtures/mediainfo_encode_queue_production.json", __DIR__)
    path |> File.read!() |> Jason.decode!()
  end

  defp mediainfo_with_audio_track(track) do
    %{
      "media" => %{
        "track" => [
          %{"@type" => "General", "Format" => "Matroska"},
          track
        ]
      }
    }
  end

  # Helper to build mediainfo for multi-track files
  # Takes {format, channels, layout, bitrate[, overrides]} tuples
  defp multi_track_mediainfo(tracks) do
    audio_tracks =
      tracks
      |> Enum.with_index()
      |> Enum.map(fn {track, idx} ->
        {format, channels, layout, bitrate, overrides} =
          case track do
            {format, channels, layout, bitrate} ->
              {format, channels, layout, bitrate, %{}}

            {format, channels, layout, bitrate, overrides} ->
              {format, channels, layout, bitrate, overrides}
          end

        Map.merge(
          %{
            "@type" => "Audio",
            "Format" => format,
            "CodecID" => format,
            "Channels" => Integer.to_string(channels),
            "ChannelLayout" => layout,
            "BitRate" => bitrate,
            "Default" => if(idx == 0, do: "Yes", else: "No")
          },
          overrides
        )
      end)

    %{
      "media" => %{
        "track" =>
          [
            %{"@type" => "General", "Duration" => "7200.0"},
            %{"@type" => "Video", "Format" => "AVC", "Width" => "1920", "Height" => "1080"}
          ] ++ audio_tracks
      }
    }
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
