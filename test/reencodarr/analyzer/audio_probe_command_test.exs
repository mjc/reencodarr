defmodule Reencodarr.Analyzer.AudioProbeCommandTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Analyzer.AudioProbe
  alias Reencodarr.Analyzer.MediaInfo.CommandExecutor

  setup do
    :meck.new(System, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(System) end)
    :ok
  end

  test "timeout and malformed probe output are bounded, explicit errors" do
    for {result, expected} <- [
          {{"", 124}, "timed out"},
          {{"", 137}, "timed out"},
          {{"invalid JSON", 0}, "invalid JSON"},
          {{"bad input", 1}, "exit 1"}
        ] do
      :meck.expect(System, :cmd, fn executable, args, _opts ->
        assert Path.basename(executable) == "timeout"
        assert ["--kill-after=2s", "20s", _ffprobe | _] = args
        assert "-probesize" in args
        assert "10000000" in args
        assert Enum.take(args, -2) == ["-i", "/input.mkv"]
        result
      end)

      assert {:error, reason} = AudioProbe.probe("/input.mkv")
      assert reason =~ expected
    end
  end

  test "missing executable does not raise or launch a command" do
    :meck.expect(System, :find_executable, fn
      "ffprobe" -> nil
      executable -> :meck.passthrough([executable])
    end)

    assert {:error, "ffprobe or timeout executable missing"} = AudioProbe.probe("/input.mkv")
    refute :meck.called(System, :cmd, :_)
  end

  test "MediaInfo results include persistent probe evidence for an ambiguous audio track" do
    path = Path.join(System.tmp_dir!(), "audio-probe-#{System.unique_integer([:positive])}.mkv")
    File.write!(path, "source")
    on_exit(fn -> File.rm(path) end)

    mediainfo = %{
      "media" => %{
        "@ref" => path,
        "track" => [
          %{"@type" => "General", "Format" => "Matroska"},
          %{
            "@type" => "Audio",
            "Format" => "A_QUICKTIME",
            "CodecID" => "A_QUICKTIME",
            "Language" => "hi",
            "Channels" => "2"
          }
        ]
      }
    }

    evidence = %{"codec_tag_string" => "enca", "channels" => 2}

    :meck.expect(System, :cmd, fn
      "mediainfo", _args, _opts ->
        {Jason.encode!(mediainfo), 0}

      executable, _args, _opts ->
        assert Path.basename(executable) == "timeout"
        {Jason.encode!(%{"streams" => [evidence]}), 0}
    end)

    assert {:ok, %{^path => saved}} = CommandExecutor.execute_single_mediainfo(path)
    assert [_, audio] = saved["media"]["track"]
    assert audio["Format"] == "A_QUICKTIME"
    assert audio["ReencodarrAudioProbe"] == evidence
  end
end
