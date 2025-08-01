defmodule Reencodarr.Analyzer.Broadway do
  @moduledoc """
  Broadway pipeline for video analysis operations.

  This module replaces the GenStage-based analyzer with a Broadway pipeline
  that provides better observability, fault tolerance, and scalability.
  """

  use Broadway
  require Logger

  alias Broadway.Message
  alias Reencodarr.Analyzer.Broadway.Producer
  alias Reencodarr.{Media, Telemetry}
  alias Reencodarr.Media.MediaInfo

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
          max_demand: 5
        ]
      ],
      batchers: [
        default: [
          batch_size: 5,
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

    Logger.debug("Processing batch of #{batch_size} videos with single mediainfo call")

    # Extract video_infos from messages
    video_infos = Enum.map(messages, & &1.data)

    # Process the batch using optimized batch mediainfo fetching
    process_batch_with_single_mediainfo(video_infos, context)

    # Log completion and emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time
    Logger.debug("Completed batch of #{batch_size} videos in #{duration}ms")
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
    Logger.debug("Processing batch of #{length(video_infos)} videos with single mediainfo call")

    # Extract all paths for batch mediainfo command
    paths = Enum.map(video_infos, & &1.path)

    case execute_batch_mediainfo_command(paths) do
      {:ok, mediainfo_map} ->
        Logger.debug("Successfully fetched mediainfo for #{length(video_infos)} videos")
        process_videos_with_batch_mediainfo(video_infos, mediainfo_map)

      {:error, reason} ->
        Logger.warning(
          "Batch mediainfo fetch failed: #{reason}, falling back to individual processing"
        )

        process_videos_individually(video_infos)
    end
  end

  defp process_videos_with_batch_mediainfo(video_infos, mediainfo_map) do
    Logger.debug("Processing #{length(video_infos)} videos with batch-fetched mediainfo")

    video_infos
    |> Task.async_stream(
      &process_video_with_mediainfo(&1, Map.get(mediainfo_map, &1.path, :no_mediainfo)),
      max_concurrency: 5,
      timeout: :timer.minutes(5),
      on_timeout: :kill_task
    )
    |> handle_task_results()
  end

  defp process_videos_individually(video_infos) do
    Logger.debug("Processing #{length(video_infos)} videos individually")

    video_infos
    |> Task.async_stream(
      &process_video_individually/1,
      max_concurrency: 5,
      timeout: :timer.minutes(5),
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

  defp process_video_with_mediainfo(video_info, :no_mediainfo) do
    Logger.warning("No mediainfo available for #{video_info.path}, processing individually")
    process_video_individually(video_info)
  end

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
        mark_video_as_failed(video_info.path, reason)
        :error
    end
  rescue
    e ->
      Logger.error("Unexpected error processing #{video_info.path}: #{inspect(e)}")
      Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
      mark_video_as_failed(video_info.path, "Exception: #{Exception.message(e)}")
      :error
  end

  defp process_video_individually(video_info) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, mediainfo} <- fetch_single_mediainfo(video_info.path),
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
        mark_video_as_failed(video_info.path, reason)
        :error
    end
  rescue
    e ->
      Logger.error("Unexpected error processing #{video_info.path}: #{inspect(e)}")
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

  defp decode_and_parse_single_mediainfo_json(json, path) do
    Logger.debug("Decoding mediainfo JSON for #{path}")

    try do
      case Jason.decode(json) do
        {:ok, data} ->
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
  end

  defp handle_decoded_single_mediainfo(%{"media" => media_item}) when is_map(media_item) do
    Logger.debug("Parsing mediainfo from single media object")
    parse_single_media_item(media_item)
  end

  defp handle_decoded_single_mediainfo(data) when is_map(data) do
    # Check if this looks like a flat structure
    if valid_flat_mediainfo?(data) do
      Logger.debug("Detected flat MediaInfo structure, wrapping in proper format")
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
    Logger.debug("Executing batch mediainfo command for #{length(paths)} files")

    case System.cmd("mediainfo", ["--Output=JSON" | paths]) do
      {json, 0} ->
        decode_and_parse_batch_mediainfo_json(json, paths)

      {error_msg, _code} ->
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp execute_batch_mediainfo_command([]), do: {:ok, %{}}

  defp decode_and_parse_batch_mediainfo_json(json, paths) do
    Logger.debug("Decoding batch mediainfo JSON for #{length(paths)} files")

    try do
      case Jason.decode(json) do
        {:ok, data} ->
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

    if valid_flat_mediainfo?(data) do
      Logger.debug("Detected flat MediaInfo structure for single file, wrapping in proper format")

      {:ok, %{path => %{"media" => data}}}
    else
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
    # Check if file exists
    if File.exists?(video_info.path) do
      {:ok, :eligible}
    else
      {:skip, "file does not exist"}
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
    # Convert mediainfo to video parameters using the existing MediaInfo module
    video_params =
      MediaInfo.to_video_params(validated_mediainfo, video_info.path)

    # Add service metadata
    attrs =
      Map.merge(video_params, %{
        "path" => video_info.path,
        "service_id" => video_info.service_id,
        "service_type" => to_string(video_info.service_type),
        "mediainfo" => validated_mediainfo
      })

    # Upsert the video record
    case Media.upsert_video(attrs) do
      {:ok, video} ->
        Logger.debug("Successfully upserted video: #{video.path}")
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
end
