defmodule Reencodarr.Analyzer.Consumer do
  use GenStage
  require Logger
  alias Reencodarr.{Media, Telemetry}

  @concurrent_files 5

  def start_link() do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:consumer, :ok, subscribe_to: [{Reencodarr.Analyzer.Producer, max_demand: @concurrent_files}]}
  end

  @impl true
  def handle_events(video_infos, _from, state) do
    # Process videos in parallel using Task.async_stream for better performance
    video_infos
    |> Task.async_stream(
      &process_video/1,
      max_concurrency: @concurrent_files,
      timeout: :timer.minutes(5),
      on_timeout: :kill_task
    )
    |> Stream.run()

    {:noreply, [], state}
  end

  defp process_video(video_info) do
    try do
      Logger.info("Starting analysis for #{video_info.path}")
      analyze_video(video_info)
      Logger.info("Completed analysis for #{video_info.path}")
    rescue
      e ->
        Logger.error("Analysis failed for #{video_info.path}: #{inspect(e)}")
        # Optionally mark video as failed or retry logic here
    end
  end

  defp analyze_video(%{path: path, service_id: service_id, service_type: service_type} = video_info) do
    # Check if we should process this video
    video = Media.get_video_by_path(path)
    force_reanalyze = Map.get(video_info, :force_reanalyze, false)

    should_process = should_process_video?(video, force_reanalyze)

    if should_process do
      case fetch_mediainfo([path]) do
        {:ok, mediainfo_map} ->
          mediainfo = Map.get(mediainfo_map, path)

          if mediainfo do
            validate_audio_metadata(mediainfo, path)
            file_size = get_in(mediainfo, ["media", "track", Access.at(0), "FileSize"])

            with size when size not in [nil, ""] <- file_size,
                 {:ok, _video} <- Media.upsert_video(%{
                   path: path,
                   mediainfo: mediainfo,
                   service_id: service_id,
                   service_type: service_type,
                   size: file_size
                 }) do
              Logger.debug("Upserted analyzed video for #{path}")
              # Emit telemetry event for successful analysis
              Telemetry.emit_analyzer_throughput(1, 0)
              :ok
            else
              nil ->
                Logger.error("Mediainfo size is empty for #{path}, skipping upsert")
              "" ->
                Logger.error("Mediainfo size is empty for #{path}, skipping upsert")
              {:error, reason} ->
                Logger.error("Failed to upsert video for #{path}: #{inspect(reason)}")
            end
          else
            Logger.error("No mediainfo found for #{path}")
          end

        {:error, reason} ->
          Logger.error("Failed to fetch mediainfo for #{path}: #{reason}")
      end
    else
      Logger.debug("Video already exists with non-zero bitrate, skipping: #{path}")
    end
  end

  defp should_process_video?(video, force_reanalyze) do
    is_nil(video) or video.bitrate == 0 or force_reanalyze
  end

  defp validate_audio_metadata(mediainfo, path) do
    tracks = get_in(mediainfo, ["media", "track"]) || []
    audio_tracks = Enum.filter(tracks, &(&1["@type"] == "Audio"))

    if Enum.empty?(audio_tracks) do
      Logger.warning("No audio tracks found in MediaInfo for #{path}")
    end

    # Check for suspicious audio metadata
    Enum.each(audio_tracks, fn track ->
      channels = Map.get(track, "Channels", "0")
      codec = Map.get(track, "CodecID", "")

      case Integer.parse(to_string(channels)) do
        {ch, _} when ch > 16 ->
          Logger.warning("Suspicious channel count (#{ch}) for #{path}")
        {0, _} ->
          Logger.warning("Zero channels reported for audio track in #{path}")
        :error ->
          Logger.warning("Invalid channel format '#{channels}' for #{path}")
        _ -> :ok
      end

      if codec == "" do
        Logger.warning("Missing audio codec information for #{path}")
      end
    end)
  end

  defp fetch_mediainfo(paths) do
    paths
    |> List.wrap()
    |> run_mediainfo_cmd()
    |> decode_and_parse_json()
  end

  defp run_mediainfo_cmd([]), do: {:ok, %{}}

  defp run_mediainfo_cmd(paths) do
    case System.cmd("mediainfo", ["--Output=JSON" | paths]) do
      {json, 0} -> {:ok, json}
      {error_msg, _code} -> {:error, error_msg}
    end
  end

  defp decode_and_parse_json({:ok, json}) do
    with {:ok, decoded} <- Jason.decode(json) do
      {:ok, parse_mediainfo(decoded)}
    else
      error ->
        Logger.error("Failed to decode JSON: #{inspect(error)}")
        {:error, :invalid_json}
    end
  end

  defp decode_and_parse_json({:error, reason}), do: {:error, reason}

  defp parse_mediainfo(json) when is_list(json) do
    json
    |> Enum.map(fn
      %{"media" => %{"@ref" => ref}} = mediainfo -> {ref, mediainfo}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp parse_mediainfo(%{"media" => %{"@ref" => ref}} = json), do: %{ref => json}
  defp parse_mediainfo(_), do: %{}
end
