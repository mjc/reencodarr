defmodule Reencodarr.Analyzer.AudioProbeTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Analyzer.AudioProbe
  alias Reencodarr.Media.{AudioTrackInfo, Video}
  alias Reencodarr.Rules.Audio

  test "ordinary and object tracks do not launch a fallback probe" do
    data = media([track("DTS", "A_DTS"), track("E-AC-3", "A_EAC3")])
    assert AudioProbe.enrich(data, "/input.mkv", fn _ -> flunk("unnecessary probe") end) == data
  end

  test "one targeted probe resolves an ambiguous ordinary codec without replacing raw metadata" do
    raw =
      Map.merge(track("A_QUICKTIME", "A_QUICKTIME"), %{"Language" => "hi", "Title" => "Hindi"})

    data = media([track("Opus", "A_OPUS"), raw])

    result =
      AudioProbe.enrich(data, "/input.mkv", fn "/input.mkv" ->
        {:ok,
         [
           %{"codec_name" => "opus"},
           %{
             "codec_name" => "ac3",
             "codec_tag_string" => "ac-3",
             "channels" => 2,
             "channel_layout" => "stereo"
           }
         ]}
      end)

    assert [_, saved] = result["media"]["track"]
    assert saved["Format"] == "A_QUICKTIME"
    assert saved["Language"] == "hi"
    assert saved["ReencodarrAudioProbe"]["codec_name"] == "ac3"
    assert [{0, _}, {1, info}] = AudioTrackInfo.all_from_mediainfo(result)
    assert info.codec == "AC-3"
    assert info.channel_layout == "stereo"
    rules = Audio.rules(%Video{mediainfo: result})
    assert {"--enc", "c:a:1=libopus"} in rules
    refute {"--enc", "c:a:0=libopus"} in rules
  end

  test "enca signaling excludes audio even if a codec name is reported" do
    result =
      AudioProbe.enrich(media([track("A_QUICKTIME", "A_QUICKTIME")]), "/input.mkv", fn _ ->
        {:ok, [%{"codec_name" => "aac", "codec_tag_string" => "enca"}]}
      end)

    assert Audio.rules(%Video{mediainfo: result}) == [
             {"--acodec", "copy"},
             {"--enc", "map=-0:a:0"}
           ]
  end

  test "codec-only probes cannot erase potentially object-based DTS, EAC3 or TrueHD" do
    for codec <- ["dts", "eac3", "truehd"] do
      result =
        AudioProbe.enrich(media([track("A_QUICKTIME", "A_QUICKTIME")]), "/input.mkv", fn _ ->
          {:ok, [%{"codec_name" => codec}]}
        end)

      assert_raise Audio.ClassificationError, fn -> Audio.rules(%Video{mediainfo: result}) end
    end
  end

  test "object branding cannot bypass failed probe evidence" do
    raw = track("DTS", "A_QUICKTIME") |> Map.put("Format_Commercial_IfAny", "DTS:X")

    result =
      AudioProbe.enrich(media([raw]), "/input.mkv", fn _ ->
        {:ok, [%{"error" => "ffprobe timed out"}]}
      end)

    error =
      assert_raise Audio.ClassificationError, fn -> Audio.rules(%Video{mediainfo: result}) end

    assert error.classification == :unidentified_audio
  end

  test "probe evidence cannot contradict a known carrier or channel count" do
    for {format, channels} <- [{"DTS", 2}, {"A_QUICKTIME", 6}] do
      raw = track(format, "unknown")

      result =
        AudioProbe.enrich(media([raw]), "/input.mkv", fn _ ->
          {:ok, [%{"codec_name" => "aac", "channels" => channels}]}
        end)

      assert_raise Audio.ClassificationError, fn -> Audio.rules(%Video{mediainfo: result}) end
    end
  end

  test "probe failure and stream-count mismatch preserve raw identity and the cause" do
    for result <- [
          {:error, "ffprobe timed out"},
          {:error, "ffprobe executable missing"},
          {:ok, []}
        ] do
      data =
        AudioProbe.enrich(media([track("A_QUICKTIME", "A_QUICKTIME")]), "/input.mkv", fn _ ->
          result
        end)

      [saved] = data["media"]["track"]
      assert saved["Format"] == "A_QUICKTIME"
      assert is_binary(saved["ReencodarrAudioProbe"]["error"])
      assert_raise Audio.ClassificationError, fn -> Audio.rules(%Video{mediainfo: data}) end
    end
  end

  test "actual bounded probe decodes JSON and reports missing input" do
    path = Path.expand("../../fixtures/mediainfo_no_statistics.mkv", __DIR__)
    assert {:ok, [%{"codec_name" => "aac"}]} = AudioProbe.probe(path)
    assert {:error, reason} = AudioProbe.probe("/does-not-exist.mkv")
    assert reason =~ "No such file"
  end

  defp media(tracks), do: %{"media" => %{"track" => tracks}}

  defp track(format, id),
    do: %{
      "@type" => "Audio",
      "Format" => format,
      "CodecID" => id,
      "Channels" => "2",
      "ChannelLayout" => "L R"
    }
end
