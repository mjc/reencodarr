defmodule Reencodarr.Rules.EncryptedAudioTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video
  alias Reencodarr.Rules
  alias Reencodarr.Rules.Audio

  test "drops protected source tracks and reindexes the retained output tracks" do
    video = video([track("AAC"), encrypted(), track("AC-3"), encrypted(), track("Opus")])

    assert Audio.rules(video) == [
             {"--acodec", "copy"},
             {"--enc", "map=-0:a:1"},
             {"--enc", "map=-0:a:3"},
             {"--enc", "c:a:0=libopus"},
             {"--enc", "b:a:0=128k"},
             {"--enc", "c:a:1=libopus"},
             {"--enc", "b:a:1=128k"}
           ]

    args = Rules.build_args(video, :encode)
    assert ["--enc", "map=-0:a:1"] in Enum.chunk_every(args, 2)
    assert ["--enc", "map=-0:a:3"] in Enum.chunk_every(args, 2)
    refute "map=-0:a:1" in Rules.build_args(video, :crf_search)
  end

  test "shifts Opus filters past retained copy-through audio" do
    atmos = Map.put(track("E-AC-3"), "Format_AdditionalFeatures", "JOC")
    surround = Map.merge(track("DTS"), %{"Channels" => "3", "ChannelLayout" => "L R LFE"})
    rules = Audio.rules(video([encrypted(), atmos, surround]))

    assert {"--enc", "map=-0:a:0"} in rules
    assert {"--enc", "c:a:1=libopus"} in rules
    assert {"--enc", "filter:a:1=pan=5.1|FL=FL|FR=FR|LFE=LFE"} in rules
    refute Enum.any?(rules, fn {_, arg} -> String.starts_with?(arg, "c:a:0=") end)
  end

  test "an all-encrypted file excludes all audio, not video or subtitles" do
    assert Audio.rules(video([encrypted(), encrypted()])) == [
             {"--acodec", "copy"},
             {"--enc", "map=-0:a:0"},
             {"--enc", "map=-0:a:1"}
           ]
  end

  test "explicit enca wins over an otherwise known codec and object branding" do
    for codec <- ["AAC", "Opus", "E-AC-3", "enca", "ENCA"] do
      protected =
        codec
        |> track()
        |> Map.put("Format_AdditionalFeatures", "JOC")
        |> Map.put("ReencodarrAudioProbe", %{"codec_tag_string" => "enca"})

      assert Audio.rules(video([protected])) == [
               {"--acodec", "copy"},
               {"--enc", "map=-0:a:0"}
             ]
    end

    assert {"--enc", "map=-0:a:0"} in Audio.rules(video([track("enca")]))
  end

  test "other unknown audio still fails and diagnostics retain its source index" do
    for unknown <- [track("A_QUICKTIME"), track("unknown"), track("")] do
      error =
        assert_raise Audio.ClassificationError, fn ->
          Audio.rules(video([encrypted(), unknown]))
        end

      assert error.track_index == 1
      assert error.classification == :unidentified_audio
    end

    invalid = Map.put(track("AAC"), "Channels", "0")

    error =
      assert_raise Audio.ClassificationError, fn ->
        Audio.rules(video([encrypted(), invalid]))
      end

    assert error.track_index == 1
  end

  test "FFmpeg preserves video, subtitles, and audio languages after exclusions" do
    dir = Path.join(System.tmp_dir!(), "encrypted-audio-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    subtitle = Path.join(dir, "subtitle.srt")
    input = Path.join(dir, "input.mkv")
    output = Path.join(dir, "output.mkv")
    File.write!(subtitle, "1\n00:00:00,000 --> 00:00:00,200\nTest subtitle\n")

    assert {"", 0} =
             System.cmd(
               "ffmpeg",
               [
                 "-nostdin",
                 "-v",
                 "error",
                 "-f",
                 "lavfi",
                 "-i",
                 "color=black:s=32x32:r=10:d=0.3",
                 "-f",
                 "lavfi",
                 "-i",
                 "anullsrc=r=48000:cl=stereo:d=0.3",
                 "-i",
                 subtitle,
                 "-map",
                 "0:v",
                 "-map",
                 "1:a",
                 "-map",
                 "1:a",
                 "-map",
                 "1:a",
                 "-map",
                 "2:s",
                 "-c:v",
                 "ffv1",
                 "-c:a",
                 "flac",
                 "-c:s",
                 "srt",
                 "-metadata:s:a:0",
                 "language=eng",
                 "-metadata:s:a:1",
                 "language=hin",
                 "-metadata:s:a:2",
                 "language=jpn",
                 input
               ],
               stderr_to_stdout: true
             )

    for {tracks, expected_audio} <- [
          {[track("FLAC"), encrypted(), track("FLAC")], ["eng", "jpn"]},
          {[encrypted(), encrypted(), encrypted()], []}
        ] do
      overrides =
        tracks
        |> video()
        |> Audio.rules()
        |> Enum.flat_map(fn
          {"--acodec", value} ->
            ["-c:a", value]

          {"--enc", arg} ->
            [key, value] = String.split(arg, "=", parts: 2)
            ["-" <> key, value]
        end)

      assert {"", 0} =
               System.cmd(
                 "ffmpeg",
                 Enum.concat([
                   ["-nostdin", "-v", "error", "-y", "-i", input, "-map", "0", "-c", "copy"],
                   overrides,
                   [output]
                 ]),
                 stderr_to_stdout: true
               )

      {json, 0} = System.cmd("ffprobe", ["-v", "error", "-show_streams", "-of", "json", output])
      %{"streams" => streams} = Jason.decode!(json)
      audio = Enum.filter(streams, &(&1["codec_type"] == "audio"))
      assert Enum.map(audio, & &1["tags"]["language"]) == expected_audio
      assert Enum.all?(audio, &(&1["codec_name"] == "opus" and &1["channel_layout"] == "stereo"))
      assert Enum.any?(streams, &(&1["codec_name"] == "ffv1"))
      assert Enum.any?(streams, &(&1["codec_name"] == "subrip"))
    end
  end

  defp video(tracks) do
    %Video{
      mediainfo: %{
        "media" => %{
          "track" => [%{"@type" => "Video", "Format" => "AVC"} | tracks]
        }
      }
    }
  end

  defp track(codec) do
    %{
      "@type" => "Audio",
      "Format" => codec,
      "CodecID" => codec,
      "Channels" => "2",
      "ChannelLayout" => "L R"
    }
  end

  defp encrypted do
    "A_QUICKTIME"
    |> track()
    |> Map.put("Language", "hi")
    |> Map.put("ReencodarrAudioProbe", %{"codec_tag_string" => "enca", "channels" => 2})
  end
end
