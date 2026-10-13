defmodule Reencodarr.Analyzer.AudioProbe do
  @moduledoc false

  alias Reencodarr.Media.AudioTrackInfo

  @spec enrich(map(), String.t(), (String.t() -> {:ok, [map()]} | {:error, String.t()})) :: map()
  def enrich(mediainfo, path, probe \\ &probe/1)

  def enrich(%{"media" => %{"track" => tracks}} = mediainfo, path, probe)
      when is_list(tracks) do
    audio = Enum.filter(tracks, &(Map.get(&1, "@type") == "Audio"))

    if Enum.any?(audio, &AudioTrackInfo.ambiguous_identity?/1) do
      evidence = probe_evidence(probe.(path), length(audio))

      {tracks, _} =
        Enum.map_reduce(tracks, 0, &enrich_track(&1, &2, evidence))

      put_in(mediainfo, ["media", "track"], tracks)
    else
      mediainfo
    end
  end

  def enrich(mediainfo, _path, _probe), do: mediainfo

  defp enrich_track(%{"@type" => "Audio"} = track, index, evidence) do
    enriched =
      if AudioTrackInfo.ambiguous_identity?(track),
        do: Map.put(track, "ReencodarrAudioProbe", Enum.at(evidence, index)),
        else: track

    {enriched, index + 1}
  end

  defp enrich_track(track, index, _evidence), do: {track, index}

  @spec probe(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def probe(path) do
    with timeout when is_binary(timeout) <- System.find_executable("timeout"),
         ffprobe when is_binary(ffprobe) <- System.find_executable("ffprobe") do
      args = [
        "--kill-after=2s",
        "20s",
        ffprobe,
        "-v",
        "quiet",
        "-show_error",
        "-select_streams",
        "a",
        "-show_entries",
        "stream=index,codec_name,codec_tag_string,profile,channels,channel_layout",
        "-of",
        "json",
        "-analyzeduration",
        "1000000",
        "-probesize",
        "10000000",
        "-i",
        path
      ]

      timeout |> System.cmd(args, stderr_to_stdout: true) |> decode_probe()
    else
      nil -> {:error, "ffprobe or timeout executable missing"}
    end
  rescue
    error in ErlangError -> {:error, "could not start ffprobe: #{Exception.message(error)}"}
  end

  defp probe_evidence({:ok, streams}, count) do
    if length(streams) == count,
      do: streams,
      else: List.duplicate(%{"error" => "ffprobe/MediaInfo audio stream counts differ"}, count)
  end

  defp probe_evidence({:error, reason}, count),
    do: List.duplicate(%{"error" => reason}, count)

  defp decode_probe({_output, status}) when status in [124, 137],
    do: {:error, "ffprobe timed out after 20 seconds"}

  defp decode_probe({output, status}) do
    case Jason.decode(output) do
      {:ok, %{"streams" => streams}} when status == 0 and is_list(streams) -> {:ok, streams}
      {:ok, %{"error" => %{"string" => reason}}} -> {:error, "ffprobe: #{reason}"}
      _ -> {:error, "ffprobe failed (exit #{status}): #{String.slice(output, -500..-1//1)}"}
    end
  end
end
