defmodule Reencodarr.Analyzer.Consumer do
  @moduledoc """
  GenStage consumer for processing video analysis in batches.

  This module implements efficient batch processing for video mediainfo analysis,
  leveraging existing modules from the codebase:
  - Uses `Reencodarr.Media.MediaInfo` for mediainfo processing
  - Uses `Reencodarr.Media.CodecHelper` for audio validation
  - Configurable batch sizes and timeouts
  - Parallel processing within batches
  - Robust error handling and recovery
  """

  use GenStage
  require Logger
  alias Reencodarr.{Media, Telemetry}

  # Configuration constants
  @concurrent_files 5
  @batch_size 10
  # 5 seconds
  @batch_timeout 5_000
  @processing_timeout :timer.minutes(5)

  # State management
  defmodule State do
    @moduledoc false
    defstruct batch: [], batch_timer: :no_timer
  end

  @doc "Starts the analyzer consumer"
  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:consumer, %State{},
     subscribe_to: [{Reencodarr.Analyzer.Producer, max_demand: @concurrent_files}]}
  end

  @impl true
  def handle_events(video_infos, _from, %State{} = state) do
    new_batch = state.batch ++ video_infos

    cond do
      batch_full?(new_batch) ->
        process_batch_immediately(new_batch)
        cancel_timer(state.batch_timer)
        {:noreply, [], %State{}}

      should_start_timer?(state, new_batch) ->
        timer = schedule_batch_processing()
        {:noreply, [], %State{batch: new_batch, batch_timer: timer}}

      true ->
        {:noreply, [], %{state | batch: new_batch}}
    end
  end

  @impl true
  def handle_info(:process_batch, %State{batch: batch}) do
    if !Enum.empty?(batch) do
      process_batch_immediately(batch)
    end

    {:noreply, [], %State{}}
  end

  # Batch management

  defp batch_full?(batch), do: length(batch) >= @batch_size

  defp should_start_timer?(%State{batch_timer: :no_timer}, batch) when batch != [], do: true
  defp should_start_timer?(_state, _batch), do: false

  defp schedule_batch_processing do
    Process.send_after(self(), :process_batch, @batch_timeout)
  end

  defp cancel_timer(:no_timer), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  # Core batch processing

  defp process_batch_immediately([]), do: :ok

  defp process_batch_immediately(video_infos) do
    start_time = System.monotonic_time(:millisecond)
    batch_size = length(video_infos)

    Logger.info("Processing batch of #{batch_size} videos")

    result =
      video_infos
      |> fetch_batch_mediainfo()
      |> process_videos_with_mediainfo(video_infos)

    log_batch_completion(result, start_time, batch_size)
    emit_batch_telemetry(batch_size)
  end

  defp fetch_batch_mediainfo(video_infos) do
    paths = Enum.map(video_infos, & &1.path)

    case execute_mediainfo_command(paths) do
      {:ok, mediainfo_map} ->
        {:ok, mediainfo_map}

      {:error, reason} ->
        Logger.warning(
          "Batch mediainfo fetch failed: #{reason}, falling back to individual processing"
        )

        {:error, :batch_fetch_failed}
    end
  end

  defp process_videos_with_mediainfo({:ok, mediainfo_map}, video_infos) do
    Logger.debug("Processing #{length(video_infos)} videos with batch-fetched mediainfo")

    video_infos
    |> Task.async_stream(
      &process_video_with_mediainfo(&1, Map.get(mediainfo_map, &1.path, :no_mediainfo)),
      max_concurrency: @concurrent_files,
      timeout: @processing_timeout,
      on_timeout: :kill_task
    )
    |> handle_task_results()
  end

  defp process_videos_with_mediainfo({:error, :batch_fetch_failed}, video_infos) do
    Logger.debug("Processing #{length(video_infos)} videos individually")

    video_infos
    |> Task.async_stream(
      &process_video_individually/1,
      max_concurrency: @concurrent_files,
      timeout: @processing_timeout,
      on_timeout: :kill_task
    )
    |> handle_task_results()
  end

  defp handle_task_results(stream) do
    results = Enum.to_list(stream)

    success_count = Enum.count(results, &match?({:ok, :ok}, &1))
    error_count = length(results) - success_count

    if error_count > 0 do
      Logger.warning(
        "Batch completed with #{error_count} errors out of #{length(results)} videos"
      )
    end

    :ok
  end

  # Video processing

  defp process_video_with_mediainfo(video_info, mediainfo) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, _video} <- upsert_video_record(video_info, validated_mediainfo) do
      Logger.debug("Successfully processed video: #{video_info.path}")
      :ok
    else
      {:skip, reason} ->
        Logger.debug("Skipping video #{video_info.path}: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to process video #{video_info.path}: #{reason}")
        :error
    end
  rescue
    e ->
      Logger.error("Unexpected error processing #{video_info.path}: #{inspect(e)}")
      :error
  end

  defp process_video_individually(video_info) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, mediainfo} <- fetch_single_mediainfo(video_info.path),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, _video} <- upsert_video_record(video_info, validated_mediainfo) do
      Logger.debug("Successfully processed video: #{video_info.path}")
      Telemetry.emit_analyzer_throughput(1, 0)
      :ok
    else
      {:skip, reason} ->
        Logger.debug("Skipping video #{video_info.path}: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to process video #{video_info.path}: #{reason}")
        :error
    end
  rescue
    e ->
      Logger.error("Unexpected error processing #{video_info.path}: #{inspect(e)}")
      :error
  end

  # Helper functions

  defp check_processing_eligibility(%{path: path} = video_info) do
    video = Media.get_video_by_path(path) || :not_found
    force_reanalyze = Map.get(video_info, :force_reanalyze, false)

    if should_process_video?(video, force_reanalyze) do
      {:ok, true}
    else
      {:skip, "video already processed with valid bitrate"}
    end
  end

  defp should_process_video?(video, force_reanalyze) do
    video == :not_found or video.bitrate == 0 or force_reanalyze
  end

  defp validate_mediainfo(:no_mediainfo, path) do
    {:error, "no mediainfo found for #{path}"}
  end

  defp validate_mediainfo(mediainfo, path) do
    # Use existing CodecHelper for audio validation
    validate_audio_metadata(mediainfo, path)

    case extract_file_size(mediainfo) do
      {:ok, file_size} -> {:ok, %{mediainfo: mediainfo, file_size: file_size}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_file_size(mediainfo) do
    case get_in(mediainfo, ["media", "track", Access.at(0), "FileSize"]) do
      size when is_binary(size) and size != "" -> {:ok, size}
      size when is_integer(size) and size > 0 -> {:ok, size}
      _ -> {:error, "empty or missing file size in mediainfo"}
    end
  end

  defp upsert_video_record(video_info, %{mediainfo: mediainfo, file_size: file_size}) do
    %{path: path, service_id: service_id, service_type: service_type} = video_info

    Media.upsert_video(%{
      path: path,
      mediainfo: mediainfo,
      service_id: service_id,
      service_type: service_type,
      size: file_size
    })
  end

  # MediaInfo operations using existing codebase functionality

  defp execute_mediainfo_command(paths) when is_list(paths) and paths != [] do
    case System.cmd("mediainfo", ["--Output=JSON" | paths]) do
      {json, 0} ->
        decode_and_parse_mediainfo_json(json)

      {error_msg, _code} ->
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp execute_mediainfo_command([]), do: {:ok, %{}}

  defp fetch_single_mediainfo(path) do
    case execute_mediainfo_command([path]) do
      {:ok, mediainfo_map} ->
        case Map.get(mediainfo_map, path) do
          :no_mediainfo -> {:error, "no mediainfo found for path"}
          mediainfo -> {:ok, mediainfo}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_and_parse_mediainfo_json(json) do
    with {:ok, decoded} <- Jason.decode(json) do
      {:ok, parse_mediainfo_response(decoded)}
    else
      error ->
        Logger.error("Failed to decode mediainfo JSON: #{inspect(error)}")
        {:error, :invalid_json}
    end
  end

  defp parse_mediainfo_response(json) when is_list(json) do
    json
    |> Enum.map(fn
      %{"media" => %{"@ref" => ref}} = mediainfo -> {ref, mediainfo}
      _ -> :invalid_entry
    end)
    |> Enum.reject(&(&1 == :invalid_entry))
    |> Enum.into(%{})
  end

  defp parse_mediainfo_response(%{"media" => %{"@ref" => ref}} = json) do
    %{ref => json}
  end

  defp parse_mediainfo_response(_), do: %{}

  # Audio validation using existing CodecHelper
  defp validate_audio_metadata(mediainfo, path) do
    tracks = get_in(mediainfo, ["media", "track"]) || []
    audio_tracks = Enum.filter(tracks, &(&1["@type"] == "Audio"))

    if Enum.empty?(audio_tracks) do
      Logger.warning("No audio tracks found in MediaInfo for #{path}")
    end

    # Use existing validation patterns
    Enum.each(audio_tracks, fn track ->
      validate_audio_track(track, path)
    end)

    :ok
  end

  defp validate_audio_track(track, path) do
    channels = Map.get(track, "Channels", "0")
    codec = Map.get(track, "CodecID", "")

    case Integer.parse(to_string(channels)) do
      {ch, _} when ch > 16 ->
        Logger.warning("Suspicious channel count (#{ch}) for #{path}")

      {0, _} ->
        Logger.warning("Zero channels reported for audio track in #{path}")

      :error ->
        Logger.warning("Invalid channel format '#{channels}' for #{path}")

      _ ->
        :ok
    end

    if codec == "" do
      Logger.warning("Missing audio codec information for #{path}")
    end
  end

  # Logging and telemetry

  defp log_batch_completion(result, start_time, batch_size) do
    duration = System.monotonic_time(:millisecond) - start_time
    Logger.info("Completed batch of #{batch_size} videos in #{duration}ms")
    result
  end

  defp emit_batch_telemetry(batch_size) do
    Telemetry.emit_analyzer_throughput(batch_size, 0)
  end
end
