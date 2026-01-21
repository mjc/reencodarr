defmodule Reencodarr.Analyzer.Processing.Pipeline do
  @moduledoc """
  Consolidated video processing pipeline with optimized batch operations.

  This module eliminates duplication by centralizing all video processing logic
  from Broadway and other analyzer components.

  Features:
  - Batch video processing with dynamic concurrency
  - MediaInfo integration and validation
  - Error handling and recovery strategies
  - Performance monitoring integration
  - Automatic cleanup of missing/empty files
  """

  require Logger
  alias Reencodarr.Analyzer.{Core.ConcurrencyManager, Core.FileOperations}
  alias Reencodarr.Analyzer.MediaInfo.CommandExecutor
  alias Reencodarr.{Media, Services}
  alias Reencodarr.Media.MediaInfoExtractor

  # Type definitions for better type safety
  @type video_info :: %{id: integer(), path: String.t()}
  @type mediainfo_data :: map()
  @type mediainfo_result_map :: %{String.t() => mediainfo_data()}
  @type processing_context :: map()
  @type processing_result :: {:ok, [map()]} | {:error, term()}

  @doc """
  Process a batch of videos with optimized MediaInfo fetching.

  This is the main entry point for batch video processing, consolidating
  logic from multiple places in the original codebase.
  """
  @spec process_video_batch([video_info()], processing_context()) :: processing_result()
  def process_video_batch(video_infos, context \\ %{}) when is_list(video_infos) do
    Logger.debug("Processing batch of #{length(video_infos)} videos")

    # Pre-filter valid files for better performance
    {valid_videos, invalid_videos_with_errors} = filter_valid_videos(video_infos)

    # Process valid videos with batch MediaInfo fetching
    case process_valid_videos(valid_videos, context) do
      {:ok, processed_videos} ->
        # Combine results - invalid videos now include their actual error reasons
        all_results = processed_videos ++ mark_invalid_videos(invalid_videos_with_errors)
        {:ok, all_results}

      error ->
        error
    end
  end

  @doc """
  Process videos individually (fallback method).

  Used when batch processing fails or for small batches.
  """
  @spec process_videos_individually([video_info()]) :: processing_result()
  def process_videos_individually(video_infos) when is_list(video_infos) do
    Logger.debug("Processing #{length(video_infos)} videos individually")

    concurrency = get_fallback_concurrency()
    timeout = ConcurrencyManager.get_processing_timeout()

    results =
      video_infos
      |> Task.async_stream(
        &process_single_video/1,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    process_async_results(results)
  end

  @doc """
  Process a single video with MediaInfo extraction.
  """
  @spec process_single_video(map()) :: {:ok, map()} | {:error, term()}
  def process_single_video(video_info) when is_map(video_info) do
    Logger.debug("Processing single video: #{video_info.path}")

    with {:ok, _stats} <- FileOperations.validate_file_for_processing(video_info.path),
         {:ok, mediainfo} <- CommandExecutor.execute_single_mediainfo(video_info.path),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, video_params} <- extract_video_params(validated_mediainfo, video_info.path) do
      # Merge with service metadata
      complete_params = merge_service_metadata(video_params, video_info)

      {:ok, {video_info, complete_params}}
    else
      {:error, reason} ->
        Logger.warning(
          "Cannot analyze video #{video_info.path}: #{reason}. Will be marked as failed."
        )

        {:error, {video_info.path, reason}}

      error ->
        error_msg = inspect(error)
        Logger.error("Failed to process video #{video_info.path}: #{error_msg}")
        {:error, {video_info.path, error_msg}}
    end
  end

  # Private functions

  defp filter_valid_videos(video_infos) do
    paths = Enum.map(video_infos, & &1.path)
    validation_results = FileOperations.validate_files_for_processing(paths)

    # Split into valid videos and handle invalid ones immediately
    {valid, invalid_with_errors} =
      Enum.reduce(video_infos, {[], []}, fn video_info, {valid_acc, invalid_acc} ->
        case Map.get(validation_results, video_info.path) do
          {:ok, _stats} ->
            {[video_info | valid_acc], invalid_acc}

          {:error, reason} ->
            # Handle cleanup immediately for missing/empty files
            handle_invalid_file(video_info, reason)
            {valid_acc, [{video_info, reason} | invalid_acc]}

          nil ->
            {valid_acc, [{video_info, "validation result not found"} | invalid_acc]}
        end
      end)

    {Enum.reverse(valid), Enum.reverse(invalid_with_errors)}
  end

  defp handle_invalid_file(video_info, reason) do
    cond do
      String.contains?(reason, "does not exist") ->
        handle_missing_file(video_info)

      String.contains?(reason, "is empty") ->
        handle_empty_file(video_info)

      true ->
        # Other errors don't need special handling here
        :ok
    end
  end

  defp handle_missing_file(video_info) do
    Logger.info("File does not exist, deleting video record: #{video_info.path}")

    case Media.get_video(video_info.id) do
      nil ->
        Logger.debug("Video #{video_info.id} already deleted")

      video ->
        case Media.delete_video_with_vmafs(video) do
          {:ok, _} ->
            Logger.info("Successfully deleted video record for missing file: #{video_info.path}")

          {:error, reason} ->
            Logger.error(
              "Failed to delete video record for #{video_info.path}: #{inspect(reason)}"
            )
        end
    end
  end

  defp handle_empty_file(video_info) do
    Logger.warning("File is empty, cleaning up: #{video_info.path}")

    # Delete the empty file
    case File.rm(video_info.path) do
      :ok ->
        Logger.info("Successfully deleted empty file: #{video_info.path}")

      {:error, reason} ->
        Logger.error("Failed to delete empty file #{video_info.path}: #{inspect(reason)}")
    end

    # Get video record and trigger rescan before deleting
    case Media.get_video(video_info.id) do
      nil ->
        Logger.debug("Video #{video_info.id} already deleted")

      video ->
        # Trigger rescan in Sonarr/Radarr before deleting the record
        trigger_service_rescan(video)

        # Delete the video record
        case Media.delete_video_with_vmafs(video) do
          {:ok, _} ->
            Logger.info("Successfully deleted video record for empty file: #{video_info.path}")

          {:error, reason} ->
            Logger.error(
              "Failed to delete video record for #{video_info.path}: #{inspect(reason)}"
            )
        end
    end
  end

  defp trigger_service_rescan(video) do
    case video.service_type do
      :sonarr ->
        trigger_sonarr_rescan(video)

      :radarr ->
        trigger_radarr_rescan(video)

      nil ->
        Logger.debug("No service type for video #{video.id}, skipping rescan")

      other ->
        Logger.warning("Unknown service type #{inspect(other)} for video #{video.id}")
    end
  end

  defp trigger_sonarr_rescan(video) do
    case video.service_id do
      nil ->
        Logger.warning("No service_id for Sonarr video #{video.id}, cannot trigger rescan")

      service_id ->
        case Integer.parse(service_id) do
          {episode_file_id, ""} ->
            do_sonarr_rescan(episode_file_id)

          _ ->
            Logger.warning("Invalid service_id for Sonarr video: #{service_id}")
        end
    end
  end

  defp do_sonarr_rescan(episode_file_id) do
    case Services.Sonarr.get_episode_file(episode_file_id) do
      {:ok, %{body: %{"seriesId" => series_id}}} when is_integer(series_id) ->
        Logger.info("Triggering Sonarr rescan for series #{series_id}")

        case Services.Sonarr.refresh_series(series_id) do
          {:ok, _} ->
            Logger.info("Successfully triggered Sonarr rescan for series #{series_id}")

          {:error, reason} ->
            Logger.error("Failed to trigger Sonarr rescan: #{inspect(reason)}")
        end

      {:ok, response} ->
        Logger.warning(
          "Could not extract series ID from episode file response: #{inspect(response)}"
        )

      {:error, reason} ->
        Logger.error("Failed to get episode file info from Sonarr: #{inspect(reason)}")
    end
  end

  defp trigger_radarr_rescan(video) do
    case video.service_id do
      nil ->
        Logger.warning("No service_id for Radarr video #{video.id}, cannot trigger rescan")

      service_id ->
        case Integer.parse(service_id) do
          {movie_file_id, ""} ->
            do_radarr_rescan(movie_file_id)

          _ ->
            Logger.warning("Invalid service_id for Radarr video: #{service_id}")
        end
    end
  end

  defp do_radarr_rescan(movie_file_id) do
    case Services.Radarr.get_movie_file(movie_file_id) do
      {:ok, %{body: %{"movieId" => movie_id}}} when is_integer(movie_id) ->
        Logger.info("Triggering Radarr rescan for movie #{movie_id}")

        case Services.Radarr.refresh_movie(movie_id) do
          {:ok, _} ->
            Logger.info("Successfully triggered Radarr rescan for movie #{movie_id}")

          {:error, reason} ->
            Logger.error("Failed to trigger Radarr rescan: #{inspect(reason)}")
        end

      {:ok, response} ->
        Logger.warning(
          "Could not extract movie ID from movie file response: #{inspect(response)}"
        )

      {:error, reason} ->
        Logger.error("Failed to get movie file info from Radarr: #{inspect(reason)}")
    end
  end

  defp process_valid_videos([], _context), do: {:ok, []}

  @spec process_valid_videos([video_info()], processing_context()) :: processing_result()
  defp process_valid_videos(valid_videos, context) do
    # Extract paths for batch MediaInfo command
    paths = Enum.map(valid_videos, & &1.path)

    case CommandExecutor.execute_batch_mediainfo(paths) do
      {:ok, mediainfo_map} ->
        process_videos_with_mediainfo(valid_videos, mediainfo_map, context)

      {:error, reason} ->
        Logger.warning(
          "Batch MediaInfo failed: #{inspect(reason)}, falling back to individual processing"
        )

        process_videos_individually(valid_videos)
    end
  end

  @spec process_videos_with_mediainfo(
          [video_info()],
          mediainfo_result_map(),
          processing_context()
        ) :: processing_result()
  defp process_videos_with_mediainfo(video_infos, mediainfo_map, _context) do
    concurrency = get_processing_concurrency()
    timeout = ConcurrencyManager.get_processing_timeout()

    Logger.debug(
      "Processing #{length(video_infos)} videos with batch MediaInfo (concurrency: #{concurrency})"
    )

    results =
      video_infos
      |> Task.async_stream(
        fn video_info ->
          # Get the full MediaInfo result (already includes "media" key)
          mediainfo = Map.get(mediainfo_map, video_info.path, :no_mediainfo)

          process_video_with_mediainfo(video_info, mediainfo)
        end,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    process_async_results(results)
  end

  defp process_video_with_mediainfo(video_info, :no_mediainfo) do
    Logger.debug("No MediaInfo available for #{video_info.path}, processing individually")
    process_single_video(video_info)
  end

  defp process_video_with_mediainfo(video_info, mediainfo) do
    Logger.debug("Processing video #{video_info.path} with batch MediaInfo")

    # Extract the "media" portion from the full mediainfo structure
    media_data =
      case mediainfo do
        %{"media" => media} -> media
        # fallback for unexpected structure
        other -> other
      end

    with {:ok, validated_mediainfo} <- validate_mediainfo(media_data, video_info.path),
         {:ok, video_params} <- extract_video_params(validated_mediainfo, video_info.path) do
      complete_params = merge_service_metadata(video_params, video_info)
      {:ok, {video_info, complete_params}}
    else
      {:error, reason} ->
        Logger.warning(
          "Cannot analyze video #{video_info.path}: #{reason}. Will be marked as failed."
        )

        {:error, {video_info.path, reason}}
    end
  catch
    :error, reason ->
      error_msg = inspect(reason)
      Logger.error("Exception processing video #{video_info.path}: #{error_msg}")
      {:error, {video_info.path, error_msg}}
  end

  defp mark_invalid_videos(invalid_videos_with_errors) do
    Enum.map(invalid_videos_with_errors, fn {video_info, reason} ->
      {:error, {video_info.path, reason}}
    end)
  end

  defp process_async_results(results) do
    {successful, failed} =
      Enum.reduce(results, {[], []}, fn
        {:ok, {:ok, video_data}}, {success, fails} ->
          {[video_data | success], fails}

        {:ok, {:skip, reason}}, {success, fails} ->
          Logger.debug("Video skipped: #{reason}")
          {success, fails}

        {:ok, {:error, path}}, {success, fails} ->
          # Record the failure using the failure tracker instead of just logging
          # Note: We don't have the video struct here, so we'll still log but also collect for reporting
          Logger.error("Video processing failed for: #{path}")
          {success, [path | fails]}

        {:exit, :timeout}, {success, fails} ->
          Logger.error("Video processing timed out")
          {success, ["timeout" | fails]}

        other, {success, fails} ->
          Logger.error("Unexpected processing result: #{inspect(other)}")
          {success, ["unknown_error" | fails]}
      end)

    # Record failures properly through the failure system if we have them
    # For now, log summary - ideally we'd have video structs to record individual failures
    if not Enum.empty?(failed) do
      Logger.warning(
        "Batch processing completed with #{length(failed)} failures: #{inspect(failed)}"
      )
    end

    {:ok, Enum.reverse(successful)}
  end

  defp validate_mediainfo(media_data, path) do
    case media_data do
      %{"track" => tracks} when is_list(tracks) ->
        # Wrap the media data back in the expected structure for MediaInfoExtractor
        {:ok, %{"media" => media_data}}

      %{"track" => _track} ->
        # Single track, also valid
        {:ok, %{"media" => media_data}}

      _ ->
        Logger.error(
          "Invalid MediaInfo media structure for #{path}: #{inspect(media_data, limit: 100)}"
        )

        {:error, "invalid media structure"}
    end
  end

  defp extract_video_params(validated_mediainfo, path) do
    case MediaInfoExtractor.extract_video_params(validated_mediainfo, path) do
      video_params when is_map(video_params) -> {:ok, video_params}
      {:error, reason} -> {:error, reason}
      error -> {:error, "video parameter extraction failed: #{inspect(error)}"}
    end
  end

  defp merge_service_metadata(video_params, video_info) do
    Map.merge(video_params, %{
      "path" => video_info.path,
      "service_id" => video_info.service_id,
      "service_type" => to_string(video_info.service_type)
    })
  end

  defp get_processing_concurrency do
    ConcurrencyManager.get_video_processing_concurrency()
  end

  defp get_fallback_concurrency do
    # Use reduced concurrency for fallback processing
    max(2, div(get_processing_concurrency(), 2))
  end
end
