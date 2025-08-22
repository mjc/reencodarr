defmodule Reencodarr.Analyzer.Broadway do
  @moduledoc """
  Broadway pipeline for video analysis operations.

  This module replaces the GenStage-based analyzer with a Broadway that provides better observability, fault tolerance, and scalability.
  """

  use Broadway
  require Logger

  alias Broadway.Message
  alias Reencodarr.Analyzer.Broadway.Producer
  alias Reencodarr.{Media, Telemetry}
  alias Reencodarr.Media.MediaInfoExtractor

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
          allowed_messages: 25,
          interval: 1000
        ]
      ],
      processors: [
        default: [
          concurrency: 1,
          max_demand: 1
        ]
      ],
      batchers: [
        default: [
          batch_size: 1,
          batch_timeout: 2_000,
          concurrency: 1
        ]
      ],
      context: %{
        concurrent_files: 5,
        processing_timeout: :timer.minutes(5)
      }
    )
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
  Trigger the producer to check for videos needing analysis.
  """
  def dispatch_available do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :producer_supervisor_not_found}
      _pid -> Producer.dispatch_available()
    end
  end

  @doc """
  Pause the analyzer.
  """
  def pause do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :producer_supervisor_not_found}
      _pid -> Producer.pause()
    end
  end

  @doc """
  Resume the analyzer.
  """
  def resume do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :producer_supervisor_not_found}
      _pid -> Producer.resume()
    end
  end

  # Alias for API compatibility
  def start, do: resume()

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Individual messages are just passed through to be batched
    message
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, context) do
    start_time = System.monotonic_time(:millisecond)
    batch_size = length(messages)

    # Extract video_infos from messages
    video_infos = Enum.map(messages, & &1.data)

    # Process the batch using optimized batch mediainfo fetching
    {{success_count, failure_count}, {success_videos, failed_videos}} =
      process_batch_with_single_mediainfo(video_infos, context)

    # Log completion and emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time

    # Create detailed log message with video IDs
    success_detail =
      if length(success_videos) > 0,
        do: " (success: #{Enum.join(success_videos, ", ")})",
        else: ""

    failure_detail =
      if length(failed_videos) > 0, do: " (failed: #{Enum.join(failed_videos, ", ")})", else: ""

    Logger.debug(
      "📊 Analyzer: Completed batch #{success_count} success, #{failure_count} failed (#{batch_size} total) in #{duration}ms#{success_detail}#{failure_detail}"
    )

    Telemetry.emit_analyzer_throughput(batch_size, 0)

    # Notify producer that batch analysis is complete
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "analyzer_events",
      {:batch_analysis_completed, batch_size}
    )

    # Also notify for each individual video for any listeners that expect it
    Enum.each(video_infos, fn video_info ->
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "analyzer_events",
        {:analysis_completed, video_info.path, :success}
      )
    end)

    # CRITICAL: Notify producer that batch processing is complete and ready for next demand
    Producer.dispatch_available()

    # Since process_batch always returns :ok, all messages are successful
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

  defp process_batch_with_single_mediainfo(video_infos, _context) do
    # Extract all paths for batch mediainfo command
    paths = Enum.map(video_infos, & &1.path)

    case execute_batch_mediainfo_command(paths) do
      {:ok, mediainfo_map} ->
        process_videos_with_batch_mediainfo(video_infos, mediainfo_map)

      {:error, _reason} ->
        process_videos_individually(video_infos)
    end
  end

  defp process_videos_with_batch_mediainfo(video_infos, mediainfo_map) do
    results =
      video_infos
      |> Task.async_stream(
        fn video_info ->
          result =
            process_video_with_mediainfo(
              video_info,
              Map.get(mediainfo_map, video_info.path, :no_mediainfo)
            )

          {result, video_info}
        end,
        max_concurrency: 5,
        timeout: :timer.minutes(5),
        on_timeout: :kill_task
      )
      |> handle_task_results()

    count_results_with_video_info(results)
  end

  defp process_videos_individually(video_infos) do
    results =
      video_infos
      |> Task.async_stream(
        fn video_info ->
          result = process_video_individually(video_info)
          {result, video_info}
        end,
        max_concurrency: 5,
        timeout: :timer.minutes(5),
        on_timeout: :kill_task
      )
      |> handle_task_results()

    count_results_with_video_info(results)
  end

  defp handle_task_results(stream) do
    results = Enum.to_list(stream)

    results
  end

  defp count_results_with_video_info(results) do
    {success_videos, failed_videos} =
      Enum.reduce(results, {[], []}, fn
        {:ok, {:ok, video_info}}, {success_acc, fail_acc} ->
          {[get_video_identifier(video_info) | success_acc], fail_acc}

        {:ok, {:error, video_info}}, {success_acc, fail_acc} ->
          {success_acc, [get_video_identifier(video_info) | fail_acc]}

        _, acc ->
          acc
      end)

    success_count = length(success_videos)
    failure_count = length(failed_videos)

    {{success_count, failure_count}, {Enum.reverse(success_videos), Enum.reverse(failed_videos)}}
  end

  defp get_video_identifier(video_info) do
    # Try to get video ID from database, fallback to path
    case Media.get_video_by_path(video_info.path) do
      %{id: id} -> "ID:#{id}"
      nil -> "Path:#{Path.basename(video_info.path)}"
    end
  rescue
    _ -> "Path:#{Path.basename(video_info.path)}"
  end

  defp process_video_with_mediainfo(video_info, :no_mediainfo) do
    process_video_individually(video_info)
  end

  defp process_video_with_mediainfo(video_info, mediainfo) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, _video} <- upsert_video_record(video_info, validated_mediainfo) do
      :ok
    else
      {:skip, _reason} ->
        :ok

      {:error, reason} ->
        mark_video_as_failed(video_info.path, reason)
        :error
    end
  rescue
    e ->
      mark_video_as_failed(video_info.path, "Exception: #{Exception.message(e)}")
      :error
  end

  defp process_video_individually(video_info) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, mediainfo} <- fetch_single_mediainfo(video_info.path),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, _video} <- upsert_video_record(video_info, validated_mediainfo) do
      :ok
    else
      {:skip, _reason} ->
        :ok

      {:error, reason} ->
        mark_video_as_failed(video_info.path, reason)
        :error
    end
  rescue
    e ->
      mark_video_as_failed(video_info.path, "Exception: #{Exception.message(e)}")
      :error
  end

  defp fetch_single_mediainfo(path) do
    case System.cmd("mediainfo", ["--Output=JSON", path]) do
      {json, 0} ->
        decode_and_parse_single_mediainfo_json(json, path)

      {error_msg, _code} ->
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp decode_and_parse_single_mediainfo_json(json, _path) do
    case Jason.decode(json) do
      {:ok, data} ->
        # Use the direct extractor instead of complex type conversion + later parsing
        handle_decoded_single_mediainfo(data)

      {:error, reason} ->
        Logger.error("JSON decode failed: #{inspect(reason)}")
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("Error parsing mediainfo JSON: #{inspect(e)}")
      Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
      {:error, "error parsing JSON: #{inspect(e)}"}
  end

  defp handle_decoded_single_mediainfo(%{"media" => media_item}) when is_map(media_item) do
    parse_single_media_item(media_item)
  end

  defp handle_decoded_single_mediainfo(data) when is_map(data) do
    # Check if this looks like a flat structure
    if valid_flat_mediainfo?(data) do
      # Return the wrapped structure directly
      {:ok, %{"media" => data}}
    else
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

  defp execute_batch_mediainfo_command(paths) when is_list(paths) and paths != [] do
    case System.cmd("mediainfo", ["--Output=JSON" | paths]) do
      {json, 0} ->
        decode_and_parse_batch_mediainfo_json(json, paths)

      {error_msg, _code} ->
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp execute_batch_mediainfo_command([]), do: {:ok, %{}}

  defp decode_and_parse_batch_mediainfo_json(json, paths) do
    case Jason.decode(json) do
      {:ok, data} ->
        # Use the direct extractor instead of complex type conversion + later parsing
        handle_decoded_mediainfo_data(data, paths)

      {:error, reason} ->
        Logger.error("JSON decode failed: #{inspect(reason)}")
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("Error parsing batch mediainfo JSON: #{inspect(e)}")
      {:error, "error parsing JSON: #{inspect(e)}"}
  end

  defp handle_decoded_mediainfo_data(media_info_list, _paths) when is_list(media_info_list) do
    parse_batch_mediainfo_list(media_info_list)
  end

  defp handle_decoded_mediainfo_data(%{"media" => media_item}, _paths) when is_map(media_item) do
    handle_single_media_object(media_item)
  end

  defp handle_decoded_mediainfo_data(data, [path]) when is_map(data) do
    handle_single_file_batch(data, path)
  end

  defp handle_decoded_mediainfo_data(data, paths) when is_map(data) and length(paths) == 1 do
    handle_flat_mediainfo_structure(data, paths)
  end

  defp handle_decoded_mediainfo_data(data, paths) do
    Logger.warning(
      "Unexpected JSON structure from batch mediainfo for #{length(paths)} files. Data type: #{inspect(data.__struct__ || :map)}, keys: #{inspect(Map.keys(data))}"
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

  defp handle_single_file_batch(data, path) do
    # Use the same logic as individual processing for consistency
    case handle_decoded_single_mediainfo(data) do
      {:ok, mediainfo} ->
        {:ok, %{path => mediainfo}}

      {:error, reason} ->
        Logger.warning("Failed to decode MediaInfo for single file batch #{path}: #{reason}")
        {:error, reason}
    end
  end

  defp handle_flat_mediainfo_structure(data, paths) do
    path = List.first(paths)

    if valid_flat_mediainfo?(data) do
      {:ok, %{path => %{"media" => data}}}
    else
      Logger.warning(
        "Unexpected JSON structure for single file #{path}: #{inspect(data, limit: :infinity)}"
      )

      {:error, "unexpected JSON structure for single file"}
    end
  end

  defp valid_flat_mediainfo?(data) when is_map(data) do
    # Check for various MediaInfo JSON structures
    has_track_key = Map.has_key?(data, "track")
    has_media_key = Map.has_key?(data, "media")
    has_file_props = Map.has_key?(data, "FileSize") and Map.has_key?(data, "Duration")
    has_video_props = Map.has_key?(data, "Width") or Map.has_key?(data, "Height")
    has_format = Map.has_key?(data, "Format")
    has_ref = Map.has_key?(data, "@ref")

    result =
      has_track_key or has_media_key or has_file_props or has_video_props or has_format or has_ref

    result
  end

  defp valid_flat_mediainfo?(_), do: false

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

      _ ->
        {:error, "no complete name found"}
    end
  end

  defp extract_complete_name(_media_item) do
    {:error, "invalid media structure"}
  end

  defp parse_single_media_item(%{"track" => tracks}) when is_list(tracks) do
    # Return the original nested structure that downstream code expects
    {:ok, %{"media" => %{"track" => tracks}}}
  end

  defp parse_single_media_item(_), do: {:error, "invalid media item structure"}

  # Helper functions for video processing

  defp check_processing_eligibility(video_info) do
    # Check if file exists
    if File.exists?(video_info.path) do
      {:ok, :eligible}
    else
      Logger.warning("File does not exist, deleting video record: #{video_info.path}")
      delete_missing_video_record(video_info.path)
      {:skip, "file does not exist - record deleted"}
    end
  end

  defp delete_missing_video_record(path) do
    case Media.get_video_by_path(path) do
      %Media.Video{} = video ->
        case Media.delete_video(video) do
          {:ok, _deleted_video} ->
            Logger.info("Successfully deleted video record for missing file: #{path}")
            :ok

          {:error, changeset} ->
            Logger.error(
              "Failed to delete video record for #{path}: #{inspect(changeset.errors)}"
            )

            :error
        end

      nil ->
        Logger.warning("Video record not found for missing file: #{path}")
        :ok
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

  defp upsert_video_record(video_info, validated_mediainfo) do
    # Extract all fields from mediainfo for VideoUpsert
    case MediaInfoExtractor.extract_video_params(validated_mediainfo, video_info.path) do
      params when is_map(params) ->
        # Convert all extracted params to string keys and add video metadata
        attrs =
          params
          |> Enum.map(fn {k, v} -> {to_string(k), v} end)
          |> Enum.into(%{})
          |> Map.merge(%{
            "path" => video_info.path,
            "service_id" => video_info.service_id,
            "service_type" => to_string(video_info.service_type),
            "mediainfo" => validated_mediainfo,
            "state" => "analyzed"
          })

        upsert_video_with_params(attrs, video_info)

      error ->
        Logger.error("MediaInfo extraction failed for #{video_info.path}: #{inspect(error)}")
        {:error, "mediainfo extraction failed"}
    end
  end

  defp upsert_video_with_params(attrs, video_info) do
    # Upsert the video record
    case Media.upsert_video(attrs) do
      {:ok, video} ->
        {:ok, video}

      {:error, changeset} ->
        Logger.error("Failed to upsert video #{video_info.path}: #{inspect(changeset.errors)}")
        {:error, "failed to upsert video"}
    end
  end

  defp mark_video_as_failed(path, reason) do
    Logger.warning("Marking video as failed due to analysis error: #{path} - #{reason}")

    case Media.get_video_by_path(path) do
      %Media.Video{} = video ->
        # Record detailed failure information based on reason
        record_analysis_failure(video, reason)

        Logger.info("Successfully recorded analysis failure for video #{video.id}")
        :ok

      nil ->
        Logger.warning("Video not found in database, cannot mark as failed: #{path}")
        :ok
    end
  end

  # Private helper to categorize and record analysis failures
  defp record_analysis_failure(video, reason) do
    failure_type = categorize_failure_reason(reason)
    record_categorized_failure(video, failure_type, reason)
  end

  defp categorize_failure_reason({:audio_validation, _}), do: :audio_validation

  defp categorize_failure_reason(reason) do
    reason_string = to_string(reason)

    cond do
      audio_related_error?(reason_string) -> :audio_metadata
      mediainfo_related_error?(reason_string) -> :mediainfo
      file_access_error?(reason_string) -> :file_access
      validation_error?(reason_string) -> :validation
      exception_error?(reason_string) -> :exception
      true -> :unknown
    end
  end

  defp audio_related_error?(reason_string) do
    String.contains?(reason_string, "Invalid audio metadata") or
      String.contains?(reason_string, "invalid channel data") or
      String.contains?(reason_string, "Audio validation failed")
  end

  defp mediainfo_related_error?(reason_string) do
    String.contains?(reason_string, "MediaInfo") or
      String.contains?(reason_string, "mediainfo")
  end

  defp file_access_error?(reason_string) do
    String.contains?(reason_string, "file") or
      String.contains?(reason_string, "access")
  end

  defp validation_error?(reason_string) do
    String.contains?(reason_string, "validation") or
      String.contains?(reason_string, "changeset")
  end

  defp exception_error?(reason_string) do
    String.contains?(reason_string, "Exception")
  end

  defp record_categorized_failure(video, :audio_validation, {_, error_msg}) do
    Reencodarr.FailureTracker.record_mediainfo_failure(
      video,
      "Audio validation failed: #{error_msg}"
    )
  end

  defp record_categorized_failure(video, :audio_metadata, reason) do
    Reencodarr.FailureTracker.record_mediainfo_failure(video, to_string(reason))
  end

  defp record_categorized_failure(video, :mediainfo, reason) do
    Reencodarr.FailureTracker.record_mediainfo_failure(video, to_string(reason))
  end

  defp record_categorized_failure(video, :file_access, reason) do
    Reencodarr.FailureTracker.record_file_access_failure(video, to_string(reason))
  end

  defp record_categorized_failure(video, :validation, reason) do
    Reencodarr.FailureTracker.record_validation_failure(video, [],
      context: %{reason: to_string(reason)}
    )
  end

  defp record_categorized_failure(video, :exception, reason) do
    Reencodarr.FailureTracker.record_unknown_failure(video, :analysis, to_string(reason))
  end

  defp record_categorized_failure(video, :unknown, reason) do
    Reencodarr.FailureTracker.record_unknown_failure(video, :analysis, to_string(reason))
  end
end
