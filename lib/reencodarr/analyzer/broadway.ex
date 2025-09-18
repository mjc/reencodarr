defmodule Reencodarr.Analyzer.Broadway do
  @moduledoc """
  Broadway pipeline for video analysis operations.

  This module replaces the GenStage-based analyzer with a Broadway pipeline
  that provides better observability, fault tolerance, and scalability.
  """

  use Broadway
  require Logger

  alias Broadway.Message

  alias Reencodarr.Analyzer.{
    Broadway.PerformanceMonitor,
    Broadway.Producer,
    ConcurrencyManager,
    FileStatCache,
    MediaInfoCache
  }

  alias Reencodarr.{Media, Telemetry}

  @doc """
  Start the Broadway pipeline.
  """
  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Producer, []},
        transformer: {__MODULE__, :transform, []},
        rate_limiting: [
          allowed_messages: 2000,
          interval: 1000
        ]
      ],
      processors: [
        default: [
          concurrency: 16,
          max_demand: 100
        ]
      ],
      batchers: [
        default: [
          batch_size: 100,
          batch_timeout: 25,
          concurrency: 1
        ]
      ],
      context: %{
        concurrent_files: 2,
        processing_timeout: :timer.minutes(5),
        mediainfo_batch_size: 5
      }
    )
    |> case do
      {:ok, _pid} = result ->
        # Start performance monitor for self-tuning after Broadway starts successfully
        case PerformanceMonitor.start_link(__MODULE__) do
          {:ok, _monitor_pid} ->
            Logger.info("Performance monitor started for self-tuning Broadway")

          {:error, {:already_started, _monitor_pid}} ->
            Logger.debug("Performance monitor already running")

          {:error, reason} ->
            Logger.warning("Failed to start performance monitor: #{inspect(reason)}")
        end

        result

      error_result ->
        error_result
    end
  end

  @doc """
  Add a video to the pipeline for processing.
  """
  def process_path(video_info) do
    Producer.add_video(video_info)
  end

  @doc """
  Check if the analyzer is running (not paused).
  """
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> Producer.running?()
    end
  end

  @doc """
  Pause the analyzer.
  """
  def pause do
    Producer.pause()
  end

  @doc """
  Resume the analyzer.
  """
  def resume do
    Producer.resume()
  end

  @doc """
  Trigger dispatch of available videos for analysis.
  """
  def dispatch_available do
    Producer.dispatch_available()
  end

  # Alias for API compatibility
  def start, do: resume()

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Route messages to the default batcher for batch processing
    Logger.debug("Broadway: Routing message to batcher for video: #{message.data.path}")
    Message.put_batcher(message, :default)
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, context) do
    start_time = System.monotonic_time(:millisecond)
    batch_size = length(messages)

    Logger.debug("Broadway: Starting batch processing of #{batch_size} videos")

    # Extract video_infos from messages
    video_infos = Enum.map(messages, & &1.data)

    Logger.debug(
      "Broadway: Batch contains video paths: #{inspect(Enum.map(video_infos, & &1.path))}"
    )

    # Process the batch using optimized batch mediainfo fetching
    # This does ALL the mediainfo gathering first, then database operations at the end
    _result = process_batch_with_single_mediainfo(video_infos, context)

    # Log completion and emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time
    Logger.debug("Broadway: Completed batch of #{batch_size} videos in #{duration}ms")

    # Report performance metrics for self-tuning
    PerformanceMonitor.record_batch_processed(batch_size, duration)

    # Get current queue length for progress calculation
    current_queue_length = Media.count_videos_needing_analysis()

    Telemetry.emit_analyzer_throughput(batch_size, current_queue_length)

    # Notify producer that batch analysis is complete
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "analyzer_events",
      {:batch_analysis_completed, batch_size}
    )

    # Return messages as-is since processing always succeeds
    messages
  end

  @doc """
  Transform raw video info into a Broadway message.
  """
  def transform(event, _opts) do
    %Message{
      data: event,
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end

  # Private functions - ported from the GenStage consumer

  defp process_batch_with_single_mediainfo(video_infos, context) do
    batch_size = length(video_infos)

    # Get current mediainfo batch size from performance monitor
    mediainfo_batch_size =
      try do
        PerformanceMonitor.get_current_mediainfo_batch_size()
      catch
        :exit, _ -> Map.get(context, :mediainfo_batch_size, 5)
      end

    log_batch_processing(batch_size, mediainfo_batch_size)

    Logger.debug("Video paths in batch: #{inspect(Enum.map(video_infos, & &1.path))}")

    # Extract all paths for batch mediainfo command
    paths = Enum.map(video_infos, & &1.path)
    Logger.debug("Broadway: Extracted #{length(paths)} paths for mediainfo")

    mediainfo_start_time = System.monotonic_time(:millisecond)

    case execute_chunked_mediainfo_command(paths, mediainfo_batch_size) do
      {:ok, mediainfo_map} ->
        mediainfo_duration = System.monotonic_time(:millisecond) - mediainfo_start_time

        # Record mediainfo batch performance for tuning
        PerformanceMonitor.record_mediainfo_batch(length(paths), mediainfo_duration)

        Logger.debug(
          "Successfully fetched mediainfo for #{length(video_infos)} videos in #{mediainfo_duration}ms"
        )

        Logger.debug("Mediainfo keys: #{inspect(Map.keys(mediainfo_map))}")
        Logger.debug("Broadway: About to process videos with batch mediainfo")
        result = process_videos_with_batch_mediainfo(video_infos, mediainfo_map)

        Logger.debug(
          "Broadway: Completed process_videos_with_batch_mediainfo with result: #{inspect(result)}"
        )

        result

      {:error, reason} ->
        Logger.warning(
          "Batch mediainfo fetch failed: #{reason}, falling back to individual processing"
        )

        Logger.debug("Broadway: About to process videos individually")
        result = process_videos_individually(video_infos)

        Logger.debug(
          "Broadway: Completed process_videos_individually with result: #{inspect(result)}"
        )

        result
    end
  end

  defp process_videos_with_batch_mediainfo(video_infos, mediainfo_map) do
    Logger.debug("Processing #{length(video_infos)} videos with batch-fetched mediainfo")

    Logger.debug(
      "Broadway: process_videos_with_batch_mediainfo - processing paths: #{inspect(Enum.map(video_infos, & &1.path))}"
    )

    # Process all videos to prepare data (without database operations)
    # Use dynamic concurrency based on system load
    optimal_concurrency = ConcurrencyManager.get_video_processing_concurrency()
    processing_timeout = ConcurrencyManager.get_processing_timeout()

    processed_videos =
      video_infos
      |> Task.async_stream(
        &prepare_video_data_with_mediainfo(&1, Map.get(mediainfo_map, &1.path, :no_mediainfo)),
        max_concurrency: optimal_concurrency,
        timeout: processing_timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    Logger.debug("Broadway: Task.async_stream completed with #{length(processed_videos)} results")

    # Separate successful and failed preparations
    {successful_data, failed_paths} = categorize_preparation_results(processed_videos)

    # Perform batch database upsert for successful preparations
    batch_upsert_and_transition_videos(successful_data, failed_paths)
  end

  defp process_videos_individually(video_infos) do
    Logger.debug("Processing #{length(video_infos)} videos individually")

    # Process all videos to prepare data (without database operations)
    # Use reduced concurrency for individual processing (fallback path)
    fallback_concurrency = max(2, div(ConcurrencyManager.get_video_processing_concurrency(), 2))
    processing_timeout = ConcurrencyManager.get_processing_timeout()

    processed_videos =
      video_infos
      |> Task.async_stream(
        &prepare_video_data_individually/1,
        max_concurrency: fallback_concurrency,
        timeout: processing_timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    # Separate successful and failed preparations
    {successful_data, failed_paths} = categorize_preparation_results(processed_videos)

    # Perform batch database upsert for successful preparations
    batch_upsert_and_transition_videos(successful_data, failed_paths)
  end

  defp categorize_preparation_results(processed_videos) do
    Logger.debug(
      "Broadway: categorize_preparation_results processing #{length(processed_videos)} results"
    )

    {successful_data, failed_paths} =
      Enum.reduce(processed_videos, {[], []}, fn
        {:ok, {:ok, video_data}}, {success_acc, fail_acc} ->
          {video_info, _attrs} = video_data
          Logger.debug("Broadway: Video #{video_info.path} prepared successfully")
          {[video_data | success_acc], fail_acc}

        {:ok, {:skip, reason}}, acc ->
          Logger.debug("Broadway: Video skipped during preparation: #{reason}")
          acc

        {:ok, {:error, path}}, {success_acc, fail_acc} ->
          Logger.error("Broadway: Video preparation failed for path: #{path}")
          {success_acc, [path | fail_acc]}

        {:exit, :timeout}, {success_acc, fail_acc} ->
          Logger.error("Broadway: Video preparation timed out")
          {success_acc, ["timeout" | fail_acc]}

        other, {success_acc, fail_acc} ->
          Logger.error("Broadway: Unexpected preparation result: #{inspect(other)}")
          {success_acc, ["unknown_error" | fail_acc]}
      end)

    Logger.info(
      "Broadway: Categorization complete - #{length(successful_data)} successful, #{length(failed_paths)} failed"
    )

    {Enum.reverse(successful_data), Enum.reverse(failed_paths)}
  end

  defp batch_upsert_and_transition_videos(successful_data, failed_paths) do
    Logger.debug(
      "Broadway: Starting batch_upsert_and_transition_videos with #{length(successful_data)} successful videos and #{length(failed_paths)} failed paths"
    )

    handle_successful_videos_if_any(successful_data, failed_paths)

    Logger.debug("Broadway: batch_upsert_and_transition_videos completed")
    :ok
  end

  # Helper function to handle successful videos conditionally
  defp handle_successful_videos_if_any([], _failed_paths) do
    Logger.debug("No videos to upsert in batch")
  end

  defp handle_successful_videos_if_any(successful_data, failed_paths) do
    handle_successful_videos(successful_data, failed_paths)
  end

  defp handle_successful_videos(successful_data, failed_paths) do
    batch_size = length(successful_data)
    log_batch_operation(batch_size)

    video_attrs_list = Enum.map(successful_data, fn {_video_info, attrs} -> attrs end)
    log_video_attributes(video_attrs_list)

    case perform_batch_upsert(video_attrs_list, successful_data) do
      {:ok, upsert_results} ->
        handle_upsert_results(successful_data, upsert_results, failed_paths)

      {:error, reason} ->
        Logger.error("Broadway: perform_batch_upsert failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp log_batch_operation(batch_size) when batch_size > 5 do
    Logger.info("Performing batch upsert for #{batch_size} videos")
  end

  defp log_batch_operation(batch_size) do
    Logger.debug("Performing batch upsert for #{batch_size} videos")
  end

  defp log_video_attributes(video_attrs_list) do
    Logger.debug("Broadway: Extracted video attributes, about to call Media.batch_upsert_videos")

    video_attrs_list
    |> Enum.with_index()
    |> Enum.each(fn {attrs, index} ->
      path = Map.get(attrs, "path", "unknown")
      state = Map.get(attrs, "state", "not_set")

      Logger.debug(
        "Broadway: Upsert attrs #{index + 1}/#{length(video_attrs_list)} for #{path} - state in attrs: #{state}"
      )
    end)
  end

  defp perform_batch_upsert(video_attrs_list, successful_data) do
    upsert_results = retry_batch_upsert(video_attrs_list, 3)

    Logger.debug(
      "Broadway: Media.batch_upsert_videos completed with #{length(upsert_results)} results"
    )

    case {upsert_results, successful_data} do
      {[], [_ | _]} ->
        Logger.error("Broadway: Batch upsert failed after retries, marking all videos as failed")

        Enum.each(successful_data, fn {video_info, _attrs} ->
          mark_video_as_failed(
            video_info.path,
            "database busy - batch upsert failed after retries"
          )
        end)

        {:error, "batch upsert failed after retries"}

      _ ->
        {:ok, upsert_results}
    end
  end

  defp handle_upsert_results(successful_data, upsert_results, failed_paths) do
    log_upsert_results(upsert_results)

    Logger.debug("handling state transitions")

    transition_results = process_state_transitions(successful_data, upsert_results)
    log_processing_summary(transition_results, failed_paths)
  end

  defp log_upsert_results(upsert_results) do
    upsert_results
    |> Enum.with_index()
    |> Enum.each(fn {result, index} ->
      case result do
        {:ok, video} ->
          Logger.debug(
            "Broadway: Upsert #{index + 1}/#{length(upsert_results)} SUCCESS for #{video.path} -> video_id: #{video.id}, state: #{video.state}"
          )

        {:error, reason} ->
          Logger.error(
            "Broadway: Upsert #{index + 1}/#{length(upsert_results)} FAILED: #{inspect(reason)}"
          )
      end
    end)
  end

  defp process_state_transitions(successful_data, upsert_results) do
    successful_data
    |> Enum.zip(upsert_results)
    |> Enum.with_index()
    |> Enum.map(fn {{{video_info, _attrs}, upsert_result}, index} ->
      Logger.debug(
        "Broadway: Processing transition #{index + 1}/#{length(successful_data)} for #{video_info.path}"
      )

      case upsert_result do
        {:ok, video} ->
          Logger.debug("Broadway: Transitioning video #{video_info.path} to analyzed state")
          transition_video_to_analyzed(video)
          :ok

        {:error, reason} ->
          Logger.error("Broadway: UPSERT FAILED for #{video_info.path}: #{inspect(reason)}")
          mark_video_as_failed(video_info.path, "upsert failed: #{inspect(reason)}")
          :error
      end
    end)
  end

  defp log_processing_summary(transition_results, failed_paths) do
    success_count = Enum.count(transition_results, &(&1 == :ok))
    error_count = length(transition_results) - success_count
    total_errors = error_count + length(failed_paths)

    Logger.info(
      "Broadway: Batch processing completed - success: #{success_count}, errors: #{total_errors}"
    )

    log_errors_if_any(total_errors, transition_results, failed_paths)
  end

  # Helper function to log errors if any exist
  defp log_errors_if_any(0, _transition_results, _failed_paths), do: :ok

  defp log_errors_if_any(total_errors, transition_results, failed_paths) do
    total_videos = length(transition_results) + length(failed_paths)

    Logger.warning("Batch completed with #{total_errors} errors out of #{total_videos} videos")
  end

  defp prepare_video_data_with_mediainfo(video_info, :no_mediainfo) do
    Logger.debug("no mediainfo available, processing individually", path: video_info.path)
    prepare_video_data_individually(video_info)
  end

  defp prepare_video_data_with_mediainfo(video_info, mediainfo) do
    Logger.debug("Preparing video data with mediainfo: #{video_info.path}")
    Logger.debug("Broadway: prepare_video_data_with_mediainfo starting for #{video_info.path}")

    try do
      with {:ok, _eligibility} <- check_processing_eligibility(video_info),
           {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
           {:ok, attrs} <- prepare_video_attributes(video_info, validated_mediainfo) do
        Logger.debug("Broadway: Successfully prepared video data for #{video_info.path}")
        {:ok, {video_info, attrs}}
      else
        {:error, reason} ->
          Logger.debug("Skipping video #{video_info.path}: #{reason}")
          Logger.debug("Broadway: Skipping video #{video_info.path}: #{reason}")
          {:skip, reason}
      end
    rescue
      e ->
        Logger.error("Unexpected error preparing #{video_info.path}: #{inspect(e)}")
        Logger.error("Broadway: Exception preparing #{video_info.path}: #{inspect(e)}")
        {:error, video_info.path}
    end
  end

  defp prepare_video_data_individually(video_info) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, mediainfo} <- fetch_single_mediainfo(video_info.path),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, attrs} <- prepare_video_attributes(video_info, validated_mediainfo) do
      {:ok, {video_info, attrs}}
    else
      {:error, reason} ->
        Logger.debug("Skipping video #{video_info.path}: #{reason}")
        {:skip, reason}
    end
  rescue
    e ->
      Logger.error("Unexpected error preparing #{video_info.path}: #{inspect(e)}")
      {:error, video_info.path}
  end

  defp prepare_video_attributes(video_info, validated_mediainfo) do
    # Use MediaInfoExtractor to convert mediainfo JSON to video parameters
    alias Reencodarr.Media.MediaInfoExtractor

    Logger.debug("Preparing video attributes for: #{video_info.path}")

    video_params = MediaInfoExtractor.extract_video_params(validated_mediainfo, video_info.path)

    # Add service metadata
    attrs =
      Map.merge(video_params, %{
        "path" => video_info.path,
        "service_id" => video_info.service_id,
        "service_type" => to_string(video_info.service_type),
        "mediainfo" => validated_mediainfo
      })

    {:ok, attrs}
  end

  defp fetch_single_mediainfo(path) do
    # Try cache first
    case MediaInfoCache.get_mediainfo(path) do
      {:ok, mediainfo_data} ->
        Logger.debug("Broadway: Using cached mediainfo for #{path}")
        {:ok, mediainfo_data}

      {:error, _reason} ->
        Logger.debug("Broadway: Cache miss or error, executing mediainfo for #{path}")
        execute_direct_single_mediainfo(path)
    end
  end

  defp execute_direct_single_mediainfo(path) do
    case System.cmd("mediainfo", ["--Output=JSON", path]) do
      {json, 0} ->
        decode_and_parse_single_mediainfo_json(json, path)

      {error_msg, _code} ->
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp decode_and_parse_single_mediainfo_json(json, path) do
    Logger.debug("Decoding mediainfo JSON for #{path}")

    case Jason.decode(json) do
      {:ok, data} ->
        handle_decoded_single_mediainfo(data)

      {:error, reason} ->
        Logger.error("JSON decode failed: #{inspect(reason)}")
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp handle_decoded_single_mediainfo(%{"media" => media_item}) when is_map(media_item) do
    Logger.debug("Parsing mediainfo from single media object")
    parse_single_media_item(media_item)
  end

  defp handle_decoded_single_mediainfo(data) when is_map(data) do
    # Check if this looks like a flat structure
    case valid_flat_mediainfo?(data) do
      true ->
        Logger.debug("Detected flat MediaInfo structure, wrapping in proper format")
        # Return the wrapped structure directly
        {:ok, %{"media" => data}}

      false ->
        Logger.error(
          "Unexpected JSON structure from mediainfo: #{inspect(data, pretty: true, limit: 5000)}"
        )

        {:error, "unexpected JSON structure"}
    end
  end

  defp handle_decoded_single_mediainfo(data) do
    Logger.error(
      "Unexpected JSON structure from mediainfo: #{inspect(data, pretty: true, limit: 5000)}"
    )

    {:error, "unexpected JSON structure"}
  end

  defp execute_chunked_mediainfo_command(paths, batch_size) do
    Logger.debug(
      "Executing chunked mediainfo for #{length(paths)} paths with batch size #{batch_size}"
    )

    # Use dynamic concurrency for mediainfo operations
    mediainfo_concurrency = ConcurrencyManager.get_mediainfo_concurrency()
    processing_timeout = ConcurrencyManager.get_processing_timeout()

    paths
    |> Enum.chunk_every(batch_size)
    |> Task.async_stream(
      fn chunk ->
        Logger.debug("Processing mediainfo chunk of #{length(chunk)} files")

        case execute_batch_mediainfo_command(chunk) do
          {:ok, chunk_map} ->
            Logger.debug("Successfully processed chunk with #{map_size(chunk_map)} results")
            chunk_map

          {:error, reason} ->
            Logger.error("Failed to process mediainfo chunk: #{inspect(reason)}")
            %{}
        end
      end,
      timeout: processing_timeout,
      max_concurrency: mediainfo_concurrency
    )
    |> Enum.reduce({:ok, %{}}, fn
      {:ok, chunk_map}, {:ok, acc_map} ->
        {:ok, Map.merge(acc_map, chunk_map)}

      {:exit, reason}, _ ->
        Logger.error("Mediainfo chunk task exited: #{inspect(reason)}")
        {:error, {:task_exit, reason}}

      _, error ->
        Logger.error("Mediainfo chunk task failed: #{inspect(error)}")
        error
    end)
  end

  defp execute_batch_mediainfo_command([]), do: {:ok, %{}}

  defp execute_batch_mediainfo_command(paths) when is_list(paths) and paths != [] do
    Logger.debug("Executing batch mediainfo command for #{length(paths)} files")
    Logger.debug("Broadway: About to execute mediainfo command for paths: #{inspect(paths)}")

    # Use cached mediainfo results when possible
    case MediaInfoCache.get_bulk_mediainfo(paths) do
      results when map_size(results) > 0 ->
        process_cached_mediainfo_results(results)

      _empty_or_error ->
        # Fallback to direct mediainfo execution
        execute_direct_batch_mediainfo(paths)
    end
  end

  defp process_cached_mediainfo_results(results) do
    {successful_results, failed_paths} = separate_mediainfo_results(results)

    if failed_paths == [] do
      Logger.debug("Broadway: All mediainfo results from cache")
      {:ok, successful_results}
    else
      Logger.debug("Broadway: Some files failed mediainfo, returning partial results")
      {:ok, successful_results}
    end
  end

  defp separate_mediainfo_results(results) do
    Enum.reduce(results, {%{}, []}, fn {path, result}, {success_acc, failed_acc} ->
      case result do
        {:ok, mediainfo_data} ->
          {Map.put(success_acc, path, mediainfo_data), failed_acc}

        {:error, _reason} ->
          {success_acc, [path | failed_acc]}
      end
    end)
  end

  defp execute_direct_batch_mediainfo(paths) do
    # Check if all files exist before running mediainfo using cached checks
    file_stats = FileStatCache.get_bulk_file_stats(paths)

    missing_files =
      Enum.filter(paths, fn path ->
        case Map.get(file_stats, path) do
          {:ok, %{exists: false}} -> true
          {:error, _} -> true
          _ -> false
        end
      end)

    case missing_files do
      [] ->
        Logger.debug("Broadway: All files exist, executing mediainfo command")

        case System.cmd("mediainfo", ["--Output=JSON" | paths], stderr_to_stdout: true) do
          {json, 0} ->
            Logger.debug("Broadway: mediainfo command completed successfully")
            decode_and_parse_batch_mediainfo_json(json, paths)

          {error_msg, code} ->
            Logger.error("Broadway: mediainfo command failed with code #{code}: #{error_msg}")
            {:error, "mediainfo command failed: #{error_msg}"}
        end

      _ ->
        Logger.error("Broadway: Missing files detected: #{inspect(missing_files)}")
        {:error, "Missing files: #{inspect(missing_files)}"}
    end
  end

  defp decode_and_parse_batch_mediainfo_json(json, paths) do
    Logger.debug("Decoding batch mediainfo JSON for #{length(paths)} files")

    case Jason.decode(json) do
      {:ok, data} ->
        handle_decoded_mediainfo_data(data, paths)

      {:error, reason} ->
        Logger.error("JSON decode failed: #{inspect(reason)}")
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp handle_decoded_mediainfo_data(media_info_list, _paths) when is_list(media_info_list) do
    Logger.debug("Parsing mediainfo from list of #{length(media_info_list)} media objects")
    parse_batch_mediainfo_list(media_info_list)
  end

  defp handle_decoded_mediainfo_data(%{"media" => media_item}, _paths) when is_map(media_item) do
    Logger.debug("Parsing mediainfo from single media object")
    handle_single_media_object(media_item)
  end

  defp handle_decoded_mediainfo_data(data, paths) when is_map(data) and length(paths) == 1 do
    handle_flat_mediainfo_structure(data, paths)
  end

  defp handle_decoded_mediainfo_data(data, _paths) do
    Logger.error(
      "Unexpected JSON structure from batch mediainfo: #{inspect(data, pretty: true, limit: 1000)}"
    )

    {:error, "unexpected JSON structure"}
  end

  defp handle_single_media_object(media_item) do
    case extract_complete_name(media_item) do
      {:ok, path} ->
        case parse_single_media_item(media_item) do
          {:ok, mediainfo} -> {:ok, %{path => mediainfo}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_flat_mediainfo_structure(data, paths) do
    path = List.first(paths)

    case valid_flat_mediainfo?(data) do
      true ->
        Logger.debug(
          "Detected flat MediaInfo structure for single file, wrapping in proper format"
        )

        {:ok, %{path => %{"media" => data}}}

      false ->
        {:error, "unexpected JSON structure for single file"}
    end
  end

  defp valid_flat_mediainfo?(data) do
    Map.has_key?(data, "track") or
      (Map.has_key?(data, "FileSize") and Map.has_key?(data, "Duration")) or
      Map.has_key?(data, "Width") or Map.has_key?(data, "Height") or
      Map.has_key?(data, "Format")
  end

  defp parse_batch_mediainfo_list(media_info_list) do
    result_map =
      Enum.reduce(media_info_list, %{}, fn media_info, acc ->
        process_media_info_item(media_info, acc)
      end)

    {:ok, result_map}
  end

  defp process_media_info_item(%{"media" => media_item}, acc) do
    case extract_complete_name(media_item) do
      {:ok, path} ->
        add_parsed_media_to_acc(media_item, path, acc)

      {:error, reason} ->
        Logger.warning("Failed to extract complete name: #{reason}")
        acc
    end
  end

  defp process_media_info_item(invalid_media_info, acc) do
    Logger.warning("Invalid media info structure: #{inspect(invalid_media_info)}")
    acc
  end

  defp add_parsed_media_to_acc(media_item, path, acc) do
    case parse_single_media_item(media_item) do
      {:ok, mediainfo} ->
        Map.put(acc, path, mediainfo)

      {:error, reason} ->
        Logger.warning("Failed to parse media item for #{path}: #{reason}")
        Map.put(acc, path, :no_mediainfo)
    end
  end

  defp extract_complete_name(%{"@ref" => path}) when is_binary(path), do: {:ok, path}

  defp extract_complete_name(%{"track" => tracks}) when is_list(tracks) do
    case Enum.find(tracks, &(Map.get(&1, "@type") == "General")) do
      %{"CompleteName" => path} when is_binary(path) ->
        {:ok, path}

      %{"Complete_name" => path} when is_binary(path) ->
        {:ok, path}

      _ ->
        {:error, "no complete name found"}
    end
  end

  defp extract_complete_name(media_item) do
    Logger.debug("Attempting to extract complete name from: #{inspect(media_item)}")
    {:error, "invalid media structure"}
  end

  defp parse_single_media_item(%{"track" => tracks}) when is_list(tracks) do
    # Return the original nested structure that downstream code expects
    {:ok, %{"media" => %{"track" => tracks}}}
  end

  defp parse_single_media_item(_), do: {:error, "invalid media item structure"}

  # Helper functions for video processing

  defp check_processing_eligibility(video_info) do
    # Check if file exists using cached file stats
    file_exists = FileStatCache.file_exists?(video_info.path)
    Logger.debug("Broadway: File existence check for #{video_info.path}: #{file_exists}")

    case file_exists do
      true -> {:ok, :eligible}
      false -> {:error, "file does not exist"}
    end
  end

  defp validate_mediainfo(mediainfo, path) do
    # Basic validation that we have the expected structure
    case mediainfo do
      %{"media" => %{"track" => tracks}} when is_list(tracks) ->
        {:ok, mediainfo}

      %{"media" => _} ->
        {:ok, mediainfo}

      _ ->
        Logger.error("Invalid mediainfo structure for #{path}: #{inspect(mediainfo)}")
        {:error, "invalid mediainfo structure"}
    end
  end

  defp transition_video_to_analyzed(%{state: state, path: path} = video)
       when state != :needs_analysis do
    Logger.debug("Video #{path} already in state #{state}, skipping transition")
    {:ok, video}
  end

  defp transition_video_to_analyzed(video) do
    # Check if video already has target codecs and can skip CRF search
    cond do
      has_av1_codec?(video) ->
        transition_to_reencoded_with_logging(video, "already has AV1 codec")

      has_opus_codec?(video) ->
        transition_to_reencoded_with_logging(video, "already has Opus audio codec")

      true ->
        # Video needs CRF search, transition to analyzed state
        transition_to_analyzed_with_logging(video)
    end
  end

  defp transition_to_reencoded_with_logging(video, reason) do
    Logger.debug("Video #{video.path} #{reason}, marking as reencoded (skipping CRF search)")

    case Media.mark_as_reencoded(video) do
      {:ok, updated_video} ->
        Logger.debug(
          "Successfully transitioned video to reencoded state: #{video.path}, video_id: #{updated_video.id}, state: #{updated_video.state}"
        )

        {:ok, updated_video}

      {:error, changeset_error} ->
        Logger.error(
          "Failed to transition video to reencoded state for #{video.path}: #{inspect(changeset_error)}"
        )

        # Return original video even if state transition fails
        {:ok, video}
    end
  end

  defp transition_to_analyzed_with_logging(video) do
    case Media.mark_as_analyzed(video) do
      {:ok, updated_video} ->
        Logger.debug(
          "Successfully transitioned video state to analyzed: #{video.path}, video_id: #{updated_video.id}, state: #{updated_video.state}"
        )

        {:ok, updated_video}

      {:error, changeset_error} ->
        Logger.error(
          "Failed to transition video state for #{video.path}: #{inspect(changeset_error)}"
        )

        # Return original video even if state transition fails
        {:ok, video}
    end
  end

  # Helper functions to check for target codecs
  defp has_av1_codec?(video) do
    Enum.any?(video.video_codecs || [], fn codec ->
      String.downcase(codec) |> String.contains?("av1")
    end)
  end

  defp has_opus_codec?(video) do
    Enum.any?(video.audio_codecs || [], fn codec ->
      String.downcase(codec) |> String.contains?("opus")
    end)
  end

  defp mark_video_as_failed(path, reason) do
    Logger.warning("Marking video as failed due to analysis error: #{path} - #{reason}")

    case Media.get_video_by_path(path) do
      {:ok, video} ->
        # Record detailed failure information based on reason
        record_analysis_failure(video, reason)

        Logger.debug("Successfully recorded analysis failure for video #{video.id}")
        :ok

      {:error, :not_found} ->
        Logger.warning("Video not found in database, cannot mark as failed: #{path}")
        :ok
    end
  end

  # Private helper to categorize and record analysis failures
  defp record_analysis_failure(video, reason) do
    cond do
      String.contains?(reason, "MediaInfo") or String.contains?(reason, "mediainfo") ->
        Reencodarr.FailureTracker.record_mediainfo_failure(video, reason)

      String.contains?(reason, "file") or String.contains?(reason, "access") ->
        Reencodarr.FailureTracker.record_file_access_failure(video, reason)

      String.contains?(reason, "validation") or String.contains?(reason, "changeset") ->
        Reencodarr.FailureTracker.record_validation_failure(video, [], context: %{reason: reason})

      String.contains?(reason, "Exception") ->
        Reencodarr.FailureTracker.record_unknown_failure(video, :analysis, reason)

      true ->
        Reencodarr.FailureTracker.record_unknown_failure(video, :analysis, reason)
    end
  end

  # Retry batch upsert with exponential backoff for database busy errors
  defp retry_batch_upsert(video_attrs_list, max_retries) do
    retry_batch_upsert(video_attrs_list, max_retries, 0)
  end

  defp retry_batch_upsert(video_attrs_list, max_retries, attempt) when attempt < max_retries do
    Media.batch_upsert_videos(video_attrs_list)
  rescue
    error in [Exqlite.Error] ->
      case error.message do
        "Database busy" ->
          wait_time = (:math.pow(2, attempt) * 100) |> round()

          Logger.warning(
            "Database busy on attempt #{attempt + 1}/#{max_retries}, retrying in #{wait_time}ms"
          )

          Process.sleep(wait_time)
          retry_batch_upsert(video_attrs_list, max_retries, attempt + 1)

        _ ->
          Logger.error("Broadway: Exception during batch upsert: #{inspect(error)}")
          Logger.error("Broadway: Stacktrace: #{inspect(__STACKTRACE__)}")
          reraise error, __STACKTRACE__
      end

    other_error ->
      Logger.error("Broadway: Exception during batch upsert: #{inspect(other_error)}")
      Logger.error("Broadway: Stacktrace: #{inspect(__STACKTRACE__)}")
      reraise other_error, __STACKTRACE__
  end

  defp retry_batch_upsert(_video_attrs_list, max_retries, attempt) when attempt >= max_retries do
    Logger.error(
      "Broadway: Failed to complete batch upsert after #{max_retries} attempts due to database busy"
    )

    # Return empty list to indicate failure - calling code should handle this
    []
  end

  # Helper function to log batch processing based on batch size
  defp log_batch_processing(batch_size, mediainfo_batch_size) when batch_size > 5 do
    Logger.info(
      "Processing batch of #{batch_size} videos with mediainfo batch size #{mediainfo_batch_size}"
    )
  end

  defp log_batch_processing(batch_size, mediainfo_batch_size) do
    Logger.debug(
      "Processing batch of #{batch_size} videos with mediainfo batch size #{mediainfo_batch_size}"
    )
  end
end
