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
    Processing.Pipeline
  }

  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.Media.{Codecs, Video}

  # Constants
  @default_processor_concurrency 16
  @default_max_demand 100
  @default_batch_size 100
  @default_batch_timeout 25
  @default_mediainfo_batch_size 5
  @default_processing_timeout :timer.minutes(5)
  @rate_limit_interval 1000
  # Retry many times for database busy - SQLite WAL mode handles concurrency well
  @max_db_retry_attempts 50

  # Rate limiting values
  @running_rate_limit 500

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
          # Use normal rate limiting - pause/resume controlled by producer state
          allowed_messages: @running_rate_limit,
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
  Add a video to the pipeline for processing - no-op, Broadway polls automatically.
  """
  def process_path(_video_info), do: :ok

  @doc """
  Check if the analyzer is running (always true now).
  """
  def running?, do: true

  @doc """
  Pause the analyzer - no-op, always runs now.
  """
  def pause, do: :ok

  @doc """
  Resume the analyzer - no-op, always runs now.
  """
  def resume, do: :ok

  @doc """
  Trigger dispatch of available videos for analysis.
  """
  def dispatch_available do
    Producer.dispatch_available()
  end

  # Alias for API compatibility
  def start, do: :ok

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

  defp finish_batch_processing(
         %{start_time: start_time, batch_size: batch_size, messages: messages},
         _video_infos
       ) do
    # Log completion and emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time
    Logger.debug("Broadway: Completed batch of #{batch_size} videos in #{duration}ms")

    # Report performance metrics for self-tuning
    PerformanceMonitor.record_batch_processed(batch_size, duration)

    # Get current queue length for progress calculation
    current_queue_length = Media.count_videos_needing_analysis()

    # Get current performance settings for UI display
    current_batch_size = PerformanceMonitor.get_current_mediainfo_batch_size()

    # Get actual throughput from PerformanceMonitor (will be 0 if no data available)
    # Convert from files/min to files/s
    current_throughput = PerformanceMonitor.get_current_throughput() / 60.0

    # Send to new dashboard via Events module
    Events.broadcast_event(:analyzer_throughput, %{
      throughput: current_throughput,
      queue_length: current_queue_length,
      batch_size: current_batch_size
    })

    # Send analyzer progress to Dashboard V2 to indicate active analysis
    # Only send progress if there's actually work remaining or active throughput
    if current_queue_length > 0 and current_throughput > 0 do
      # Show progress based on queue activity - indicate we're actively processing
      percent =
        if current_queue_length > 0, do: round(1 / (current_queue_length + 1) * 100), else: 0

      Events.broadcast_event(:analyzer_progress, %{
        count: 1,
        total: current_queue_length + 1,
        percent: percent
      })
    end

    # Note: Don't send progress events if queue is empty or no throughput
    # This prevents showing "processing" when analyzer is actually idle

    # Send telemetry for analyzer progress - but don't send misleading count/total data
    # since we don't track the initial total when analysis started.
    # The dashboard will show throughput which is accurate.

    # Notify producer that batch analysis is complete
    Events.broadcast_event(
      :batch_analysis_completed,
      %{batch_size: batch_size}
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
    # Filter videos by their analysis needs and handle unchanged files
    {videos_needing_analysis, videos_with_unchanged_mediainfo} =
      Enum.split_with(video_infos, &needs_full_analysis?/1)

    # Process videos with unchanged MediaInfo by transitioning them to analyzed state
    process_unchanged_mediainfo_videos(videos_with_unchanged_mediainfo)

    if Enum.empty?(videos_needing_analysis) do
      Logger.debug(
        "No videos need MediaInfo analysis in this batch, all filtered out or transitioned"
      )

      :ok
    else
      process_filtered_videos(videos_needing_analysis, context)
    end
  end

  # Helper to determine if video needs full analysis (reduces nesting)
  defp needs_full_analysis?(video_info) do
    case Media.get_video(video_info.id) do
      %{state: :needs_analysis} = video ->
        video_needs_analysis?(video, video_info)

      %{state: state} ->
        Logger.debug(
          "Skipping video #{video_info.path} - already in #{state} state, not needs_analysis"
        )

        false

      nil ->
        Logger.warning("Video not found during analysis: #{video_info.path}")
        false
    end
  end

  # Determine analysis needs for videos in :needs_analysis state
  defp video_needs_analysis?(%{mediainfo: nil}, _video_info), do: true

  defp video_needs_analysis?(%{mediainfo: _mediainfo} = video, video_info) do
    case {has_valid_mediainfo?(video), has_unchanged_file_size?(video, video_info)} do
      # Valid MediaInfo + unchanged file = no analysis needed
      {true, true} -> false
      # Valid MediaInfo + changed file = needs re-analysis
      {true, false} -> true
      # Invalid MediaInfo = needs analysis regardless
      {false, _} -> true
    end
  end

  # Helper function to check if file size has changed
  defp has_unchanged_file_size?(video, video_info) do
    case File.stat(video_info.path) do
      {:ok, %File.Stat{size: current_size}} ->
        current_size == video.size

      {:error, _} ->
        # File doesn't exist or can't be read, treat as changed
        false
    end
  end

  # Helper function to check if MediaInfo is valid and complete
  defp has_valid_mediainfo?(video) do
    # Check for required fields that indicate complete MediaInfo
    is_number(video.duration) && video.duration > 0 &&
      is_number(video.bitrate) && video.bitrate > 0
  end

  # Process videos that have MediaInfo but unchanged file size by transitioning to analyzed
  defp process_unchanged_mediainfo_videos([]), do: :ok

  defp process_unchanged_mediainfo_videos(videos_with_unchanged_mediainfo) do
    Logger.debug(
      "Transitioning #{length(videos_with_unchanged_mediainfo)} videos with unchanged MediaInfo to analyzed state"
    )

    Enum.each(videos_with_unchanged_mediainfo, &process_single_unchanged_video/1)
  end

  # Helper to reduce nesting in unchanged video processing
  defp process_single_unchanged_video(video_info) do
    case Media.get_video(video_info.id) do
      %Video{state: :needs_analysis} = video ->
        try_mark_video_as_analyzed(video, video_info.path)

      %Video{state: state} ->
        Logger.debug(
          "Skipping video #{video_info.path} - already in #{state} state, no transition needed"
        )

      nil ->
        Logger.warning("Video not found for transition: #{video_info.path}")
    end
  end

  defp try_mark_video_as_analyzed(video, path) do
    # Check if video has required fields for analyzed state
    if has_required_mediainfo_fields?(video) do
      case Media.mark_as_analyzed(video) do
        {:ok, _updated_video} ->
          Logger.debug(
            "Transitioned video #{path} to analyzed (unchanged file size with existing MediaInfo)"
          )

        {:error, reason} ->
          Logger.warning(
            "Failed to transition video #{path} to analyzed state: #{inspect(reason)}"
          )
      end
    else
      Logger.debug(
        "Skipping transition for #{path} - missing required mediainfo fields (bitrate: #{video.bitrate}, width: #{video.width}, height: #{video.height})"
      )
    end
  end

  # Check if video has the required fields to transition to analyzed state
  defp has_required_mediainfo_fields?(%Video{} = video) do
    is_integer(video.bitrate) and video.bitrate > 0 and
      is_integer(video.width) and video.width > 0 and
      is_integer(video.height) and video.height > 0
  end

  defp process_filtered_videos(videos_needing_analysis, context) do
    # Then filter videos needing analysis by filename patterns to skip MediaInfo
    {encoded_filename_videos, videos_needing_mediainfo} =
      Enum.split_with(videos_needing_analysis, fn video_info ->
        has_av1_in_filename?(video_info) || has_opus_in_filename?(video_info)
      end)

    # Process encoded filename videos directly without MediaInfo - transition them to encoded state
    Enum.each(encoded_filename_videos, fn video ->
      # Debug log to see if we're processing already-encoded videos
      current_video = Media.get_video(video.id)

      Logger.debug(
        "Processing filename-detected video: #{video.path}, current state: #{current_video.state}"
      )

      cond do
        has_av1_in_filename?(video) ->
          transition_video_to_analyzed(current_video)

        has_opus_in_filename?(video) ->
          transition_video_to_analyzed(current_video)
      end
    end)

    # Process remaining videos through MediaInfo pipeline if any
    if videos_needing_mediainfo != [] do
      {:ok, mediainfo_processed} =
        Pipeline.process_video_batch(
          videos_needing_mediainfo,
          context
        )

      batch_upsert_and_transition_videos(mediainfo_processed, [])
    else
      :ok
    end
  end

  # Database operations and state transitions

  defp batch_upsert_and_transition_videos(processed_results, failed_paths) do
    Logger.debug(
      "Broadway: Starting batch_upsert_and_transition_videos with #{length(processed_results)} processed results and #{length(failed_paths)} failed paths"
    )

    # Separate successful video data from skipped/failed results
    {successful_videos, additional_failed_paths} = categorize_pipeline_results(processed_results)

    Logger.debug(
      "Broadway: Found #{length(successful_videos)} successful and #{length(additional_failed_paths)} failed"
    )

    # Only proceed with upsert if we have successful videos
    if length(successful_videos) > 0 do
      # Extract video attributes from successful videos
      video_attrs_list = Enum.map(successful_videos, fn {_video_info, attrs} -> attrs end)

      case perform_batch_upsert(video_attrs_list, successful_videos) do
        {:ok, upsert_results} ->
          handle_upsert_results(
            successful_videos,
            upsert_results,
            failed_paths ++ additional_failed_paths
          )

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
      {video_info, attrs} = video_data, {success_acc, fail_acc}
      when is_map(video_info) and is_map(attrs) ->
        {[video_data | success_acc], fail_acc}

      # Skipped video
      {:skip, reason}, {success_acc, fail_acc} ->
        Logger.debug("Broadway: Video skipped during pipeline processing: #{reason}")
        {success_acc, [reason | fail_acc]}

      # Failed video processing - now includes error reason
      {:error, {path, reason}}, {success_acc, fail_acc} ->
        Logger.debug("Broadway: Video failed during pipeline processing: #{path} - #{reason}")
        {success_acc, [{path, reason} | fail_acc]}

      # Legacy format without reason
      {:error, path}, {success_acc, fail_acc} when is_binary(path) ->
        Logger.debug("Broadway: Video failed during pipeline processing: #{path}")
        {success_acc, [{path, "unknown error"} | fail_acc]}

      # Unexpected format
      other, {success_acc, fail_acc} ->
        Logger.warning("Broadway: Unexpected pipeline result format: #{inspect(other)}")
        {success_acc, [{"unknown_path", "unexpected format"} | fail_acc]}
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
        Logger.warning(
          "Broadway: Batch upsert failed after #{@max_db_retry_attempts} retries due to database busy. " <>
            "Broadway will retry the batch automatically."
        )

        # Return error to trigger Broadway retry - don't mark as failed for DB busy
        {:error, :database_busy_retry_later}

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

    # Mark failed paths as failed in the database with error reasons
    Enum.each(failed_paths, fn
      {path, reason} -> mark_video_as_failed(path, reason)
      path when is_binary(path) -> mark_video_as_failed(path, "processing failed")
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

  @doc """
  Public function for testing - transitions a video to analyzed state with codec optimization.
  """
  def transition_video_to_analyzed(%{state: state, path: path} = video)
      when state != :needs_analysis do
    Logger.debug("Video #{path} already in state #{state}, skipping transition")
    {:ok, video}
  end

  def transition_video_to_analyzed(video) do
    # Use pure business logic to determine what should happen, then persist
    transition_decision = determine_video_transition_decision(video)
    execute_transition_decision(video, transition_decision)
  end

  @doc """
  Pure function that determines what transition should happen for a video.
  Returns a tuple indicating the target state and reason.
  This function has no side effects and is easily testable.
  """
  def determine_video_transition_decision(video) do
    cond do
      has_av1_codec?(video) ->
        {:encoded, "already has AV1 codec"}

      has_av1_in_filename?(video) ->
        {:encoded, "filename indicates AV1 encoding"}

      has_opus_codec?(video) ->
        {:encoded, "already has Opus audio codec"}

      true ->
        {:analyzed, "needs CRF search"}
    end
  end

  # Database persistence - handles the actual state transitions
  defp execute_transition_decision(video, {target_state, reason}) do
    case target_state do
      :encoded ->
        persist_encoded_state(video, reason)

      :analyzed ->
        persist_analyzed_state(video)
    end
  end

  # Database persistence functions
  defp persist_encoded_state(video, reason) do
    Logger.debug("Video #{video.path} #{reason}, marking as encoded (skipping all processing)")

    case Media.mark_as_encoded(video) do
      {:ok, updated_video} ->
        Logger.debug(
          "Successfully transitioned video to encoded state: #{video.path}, video_id: #{updated_video.id}, state: #{updated_video.state}"
        )

        {:ok, updated_video}

      {:error, changeset_error} ->
        Logger.error(
          "Failed to transition video to encoded state for #{video.path}: #{inspect(changeset_error)}"
        )

        {:ok, video}
    end
  end

  defp persist_analyzed_state(video) do
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

        {:ok, video}
    end
  end

  # Pure helper functions to check for target codecs using Media.Codecs
  def has_av1_codec?(%{video_codecs: video_codecs}) when not is_nil(video_codecs) do
    Codecs.has_av1_codec?(video_codecs)
  end

  def has_av1_codec?(_), do: false

  def has_av1_in_filename?(%{path: path}) do
    # Check if filename contains AV1 indicators (case insensitive)
    filename = Path.basename(path)
    lowercase_filename = String.downcase(filename)
    String.contains?(lowercase_filename, "av1")
  end

  def has_opus_codec?(%{audio_codecs: audio_codecs}) when is_list(audio_codecs) do
    Codecs.has_opus_audio?(audio_codecs)
  end

  def has_opus_codec?(_), do: false

  def has_opus_in_filename?(video) do
    # Check if filename contains Opus indicators (case insensitive)
    filename = Path.basename(video.path)
    lowercase_filename = String.downcase(filename)
    String.contains?(lowercase_filename, "opus")
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
        Logger.warning("Video not found in database, deleting orphan file: #{path}")

        case File.rm(path) do
          :ok ->
            Logger.info("Successfully deleted orphan file: #{path}")

          {:error, reason} ->
            Logger.error("Failed to delete orphan file #{path}: #{inspect(reason)}")
        end

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
          # Exponential backoff with max cap at 10 seconds
          base_wait = (:math.pow(2, attempt) * 100) |> round()
          wait_time = min(base_wait, 10_000)

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
