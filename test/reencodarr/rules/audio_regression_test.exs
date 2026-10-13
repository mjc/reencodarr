defmodule Reencodarr.Rules.AudioRegressionTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video
  alias Reencodarr.Rules.Audio

  test "canonical Opus layouts do not get a needless remix" do
    for {channels, layout} <- [
          {1, "C"},
          {2, "L R"},
          {3, "C L R"},
          {4, "L R Lb Rb"},
          {5, "L R C Lb Rb"},
          {6, "L R C LFE Lb Rb"},
          {7, "L R C LFE Cs Ls Rs"},
          {8, "FL+FR+FC+LFE+BL+BR+SL+SR"}
        ] do
      data = video(layout).mediainfo

      data =
        put_in(data, ["media", "track", Access.at(0), "Channels"], Integer.to_string(channels))

      rules = Audio.rules(%Video{mediainfo: data})
      refute Enum.any?(rules, fn {_, arg} -> String.starts_with?(arg, "filter:a:0=") end)
    end
  end

  test "DTS-HD MA 2.1 preserves LFE when converting to standard Opus" do
    for layout <- ["L R LFE", "2.1", "FL+FR+LFE", "LFE  R  L"] do
      rules = Audio.rules(video(layout))
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "filter:a:0=pan=5.1|FL=FL|FR=FR|LFE=LFE"} in rules
      assert {"--enc", "c:a:1=libopus"} in rules
      refute Enum.any?(rules, fn {_, arg} -> String.starts_with?(arg, "filter:a:1=") end)
    end
  end

  test "an explicitly protected Hindi track is excluded from the encode" do
    track = %{
      "@type" => "Audio",
      "Format" => "A_QUICKTIME",
      "CodecID" => "A_QUICKTIME",
      "Channels" => "2",
      "Language" => "hi",
      "ReencodarrAudioProbe" => %{"codec_tag_string" => "enca", "channels" => 2}
    }

    assert Audio.rules(%Video{mediainfo: %{"media" => %{"track" => [track]}}}) == [
             {"--acodec", "copy"},
             {"--enc", "map=-0:a:0"}
           ]
  end

  test "real Opus output retains 2.1 speakers, silent padding, and the second stereo track" do
    rules = Audio.rules(video("L R LFE"))

    {"--enc", "filter:a:0=" <> filter} =
      Enum.find(rules, fn {_, value} -> String.starts_with?(value, "filter:a:0=") end)

    path = Path.join(System.tmp_dir!(), "audio-layout-#{System.unique_integer([:positive])}.mkv")
    on_exit(fn -> File.rm(path) end)

    args = [
      "-nostdin",
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "aevalsrc=0.1*sin(2*PI*440*t)|0.1*sin(2*PI*880*t)|0.1*sin(2*PI*80*t):s=48000:d=0.3:c=2.1",
      "-f",
      "lavfi",
      "-i",
      "anullsrc=r=48000:cl=stereo:d=0.3",
      "-map",
      "0:a",
      "-map",
      "1:a",
      "-filter:a:0",
      filter,
      "-c:a",
      "libopus",
      "-b:a:0",
      "256k",
      "-b:a:1",
      "128k",
      "-metadata:s:a:0",
      "language=jpn",
      "-metadata:s:a:1",
      "language=eng",
      "-disposition:a:0",
      "default",
      "-disposition:a:1",
      "0",
      path
    ]

    assert {"", 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    {json, 0} = System.cmd("ffprobe", ["-v", "error", "-show_streams", "-of", "json", path])
    assert %{"streams" => [first, second]} = Jason.decode!(json)
    assert first["codec_name"] == "opus"
    assert first["channel_layout"] == "5.1"
    assert first["tags"]["language"] == "jpn"
    assert first["disposition"]["default"] == 1
    assert second["channel_layout"] == "stereo"
    assert second["tags"]["language"] == "eng"
    assert second["disposition"]["default"] == 0

    {pcm, 0} =
      System.cmd("ffmpeg", ["-v", "error", "-i", path, "-map", "0:a:0", "-f", "f32le", "-"])

    frames =
      for <<l::float-little-32, r::float-little-32, c::float-little-32, lfe::float-little-32,
            bl::float-little-32, br::float-little-32 <- pcm>>,
          do: [l, r, c, lfe, bl, br]

    channels = frames |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

    for {channel, frequency} <- [{0, 440}, {1, 880}, {3, 80}] do
      assert tone_power(Enum.at(channels, channel), frequency) > 0.001

      for other <- [440, 880, 80] -- [frequency] do
        assert tone_power(Enum.at(channels, channel), other) < 0.00001
      end
    end

    for channel <- [2, 4, 5] do
      assert Enum.all?(Enum.at(channels, channel), &(abs(&1) < 0.0001))
    end
  end

  defp tone_power(samples, frequency) do
    {real, imaginary} =
      samples
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {sample, i}, {r, im} ->
        phase = 2 * :math.pi() * frequency * i / 48_000
        {r + sample * :math.cos(phase), im + sample * :math.sin(phase)}
      end)

    (real * real + imaginary * imaginary) / (length(samples) * length(samples))
  end

  defp video(layout) do
    %Video{
      mediainfo: %{
        "media" => %{
          "track" => [
            %{
              "@type" => "Audio",
              "Format" => "DTS",
              "CodecID" => "A_DTS",
              "Format_Commercial_IfAny" => "DTS-HD Master Audio",
              "Format_AdditionalFeatures" => "XLL",
              "Channels" => "3",
              "ChannelLayout" => layout,
              "BitRate" => "1905127"
            },
            %{
              "@type" => "Audio",
              "Format" => "FLAC",
              "CodecID" => "A_FLAC",
              "Channels" => "2",
              "ChannelLayout" => "L R",
              "BitRate" => "654091"
            }
          ]
        }
      }
    }
  end
end
