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
    Broadway.Producer
  }

  alias Reencodarr.{Media, Telemetry}

  # Constants
  @default_processor_concurrency 16
  @default_max_demand 100
  @default_batch_size 100
  @default_batch_timeout 25
  @default_mediainfo_batch_size 5
  @default_processing_timeout :timer.minutes(5)
  @initial_rate_limit_messages 500  # Conservative start
  @rate_limit_interval 1000
  @max_db_retry_attempts 3

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
          allowed_messages: @initial_rate_limit_messages,
          interval: @rate_limit_interval
        ]
      ],
      processors: [
        default: [
          concurrency: @default_processor_concurrency,
          max_demand: @default_max_demand
        ]
      ],
      batchers: [
        default: [
          batch_size: @default_batch_size,
          batch_timeout: @default_batch_timeout,
          concurrency: 1
        ]
      ],
      context: %{
        concurrent_files: 2,
        processing_timeout: @default_processing_timeout,
        mediainfo_batch_size: @default_mediainfo_batch_size
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
    batch_metrics = start_batch_processing(messages)
    video_infos = extract_video_infos(messages)

    # Process the batch using optimized batch mediainfo fetching
    _result = process_batch_with_single_mediainfo(video_infos, context)

    finish_batch_processing(batch_metrics, video_infos)
  end

  # Private batch processing helpers

  defp start_batch_processing(messages) do
    start_time = System.monotonic_time(:millisecond)
    batch_size = length(messages)

    Logger.debug("Broadway: Starting batch processing of #{batch_size} videos")

    %{start_time: start_time, batch_size: batch_size, messages: messages}
  end

  defp extract_video_infos(messages) do
    video_infos = Enum.map(messages, & &1.data)

    Logger.debug(
      "Broadway: Batch contains video paths: #{inspect(Enum.map(video_infos, & &1.path))}"
    )

    video_infos
  end

  defp finish_batch_processing(%{start_time: start_time, batch_size: batch_size, messages: messages}, _video_infos) do
    # Log completion and emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time
    Logger.debug("Broadway: Completed batch of #{batch_size} videos in #{duration}ms")

    # Report performance metrics for self-tuning
    PerformanceMonitor.record_batch_processed(batch_size, duration)

    # Get current queue length for progress calculation
    current_queue_length = Media.count_videos_needing_analysis()

    # Get current performance settings for UI display
    current_rate_limit = PerformanceMonitor.get_current_rate_limit()
    current_batch_size = PerformanceMonitor.get_current_mediainfo_batch_size()

    # Get actual throughput from PerformanceMonitor (will be 0 if no data available)
    current_throughput = PerformanceMonitor.get_current_throughput() / 60.0  # Convert from files/min to files/s

    Telemetry.emit_analyzer_throughput(current_throughput, current_queue_length, current_rate_limit, current_batch_size)

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
    Logger.debug("Processing batch of #{length(video_infos)} videos using consolidated Pipeline")

    # Use the new consolidated processing pipeline
    {:ok, processed_videos} = Reencodarr.Analyzer.Processing.Pipeline.process_video_batch(video_infos, context)
    Logger.debug("Pipeline processed #{length(processed_videos)} videos successfully")
    batch_upsert_and_transition_videos(processed_videos, [])
  end

  # Database operations and state transitions

  defp batch_upsert_and_transition_videos(processed_results, failed_paths) do
    Logger.debug(
      "Broadway: Starting batch_upsert_and_transition_videos with #{length(processed_results)} processed results and #{length(failed_paths)} failed paths"
    )

    # Separate successful video data from skipped/failed results
    {successful_videos, additional_failed_paths} = categorize_pipeline_results(processed_results)

    Logger.debug("Broadway: Found #{length(successful_videos)} successful and #{length(additional_failed_paths)} failed")

    # Only proceed with upsert if we have successful videos
    if length(successful_videos) > 0 do
      # Extract video attributes from successful videos
      video_attrs_list = Enum.map(successful_videos, fn {_video_info, attrs} -> attrs end)

      case perform_batch_upsert(video_attrs_list, successful_videos) do
        {:ok, upsert_results} ->
          handle_upsert_results(successful_videos, upsert_results, failed_paths ++ additional_failed_paths)

        {:error, reason} ->
          Logger.error("Broadway: perform_batch_upsert failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.debug("Broadway: No successful videos to upsert")
      # Still handle any failed paths
      log_processing_summary([], failed_paths ++ additional_failed_paths)
    end

    Logger.debug("Broadway: batch_upsert_and_transition_videos completed")
    :ok
  end

  # Helper function to separate successful video data from errors/skips
  defp categorize_pipeline_results(processed_results) do
    Enum.reduce(processed_results, {[], []}, fn
      # Successful video processing - has video_info and attrs
      {video_info, attrs} = video_data, {success_acc, fail_acc} when is_map(video_info) and is_map(attrs) ->
        {[video_data | success_acc], fail_acc}

      # Skipped video
      {:skip, reason}, {success_acc, fail_acc} ->
        Logger.debug("Broadway: Video skipped during pipeline processing: #{reason}")
        {success_acc, [reason | fail_acc]}

      # Failed video processing
      {:error, path}, {success_acc, fail_acc} ->
        Logger.debug("Broadway: Video failed during pipeline processing: #{path}")
        {success_acc, [path | fail_acc]}

      # Unexpected format
      other, {success_acc, fail_acc} ->
        Logger.warning("Broadway: Unexpected pipeline result format: #{inspect(other)}")
        {success_acc, ["unknown_error" | fail_acc]}
    end)
  end

  # Database operations and state transitions

  defp perform_batch_upsert(video_attrs_list, successful_data) do
    upsert_results = retry_batch_upsert(video_attrs_list, @max_db_retry_attempts)

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

    # Mark failed paths as failed in the database
    Enum.each(failed_paths, fn path ->
      mark_video_as_failed(path, "processing failed")
    end)

    log_errors_if_any(total_errors, transition_results, failed_paths)
  end

  # Helper function to log errors if any exist
  defp log_errors_if_any(0, _transition_results, _failed_paths), do: :ok

  defp log_errors_if_any(total_errors, transition_results, failed_paths) do
    total_videos = length(transition_results) + length(failed_paths)

    Logger.warning("Batch completed with #{total_errors} errors out of #{total_videos} videos")
  end

  # Video state transition functions

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

      has_av1_in_filename?(video) ->
        transition_to_reencoded_with_logging(video, "filename indicates AV1 encoding")

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
  def has_av1_codec?(video) do
    Reencodarr.Media.Codecs.has_av1_codec?(video.video_codecs)
  end

  def has_av1_in_filename?(video) do
    # Check if filename contains AV1 indicators (case insensitive)
    filename = Path.basename(video.path)
    lowercase_filename = String.downcase(filename)
    has_av1 = String.contains?(lowercase_filename, "av1")

    if has_av1 do
      Logger.info("AV1 filename detected: #{filename} (video ID: #{video.id})")
    end

    has_av1
  end

  def has_opus_codec?(video) do
    Reencodarr.Media.Codecs.has_opus_audio?(video.audio_codecs)
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
end
