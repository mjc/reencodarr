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
  """

  require Logger
  alias Reencodarr.Analyzer.{Core.ConcurrencyManager, Core.FileOperations}
  alias Reencodarr.Analyzer.MediaInfo.CommandExecutor
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
    {valid_videos, invalid_videos} = filter_valid_videos(video_infos)

    # Process valid videos with batch MediaInfo fetching
    case process_valid_videos(valid_videos, context) do
      {:ok, processed_videos} ->
        # Combine results
        all_results = processed_videos ++ mark_invalid_videos(invalid_videos)
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
  @spec process_single_video(map()) :: {:ok, map()} | {:skip, term()} | {:error, term()}
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
        Logger.debug("Skipping video #{video_info.path}: #{reason}")
        {:skip, reason}

      error ->
        Logger.error("Failed to process video #{video_info.path}: #{inspect(error)}")
        {:error, video_info.path}
    end
  rescue
    e ->
      Logger.error("Exception processing video #{video_info.path}: #{inspect(e)}")
      {:error, video_info.path}
  end

  # Private functions

  defp filter_valid_videos(video_infos) do
    paths = Enum.map(video_infos, & &1.path)
    validation_results = FileOperations.validate_files_for_processing(paths)

    Enum.split_with(video_infos, fn video_info ->
      case Map.get(validation_results, video_info.path) do
        {:ok, _stats} -> true
        _ -> false
      end
    end)
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
          # Extract the "media" portion from the MediaInfo result
          mediainfo =
            case Map.get(mediainfo_map, video_info.path, :no_mediainfo) do
              :no_mediainfo -> :no_mediainfo
              result when is_map(result) -> Map.get(result, "media", :no_mediainfo)
              _ -> :no_mediainfo
            end

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
        Logger.debug("Skipping video #{video_info.path}: #{reason}")
        {:skip, reason}
    end
  rescue
    e ->
      Logger.error("Exception processing video #{video_info.path}: #{inspect(e)}")
      {:error, video_info.path}
  end

  defp mark_invalid_videos(invalid_videos) do
    Enum.map(invalid_videos, fn video_info ->
      {:skip, "file validation failed: #{video_info.path}"}
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
    if length(failed) > 0 do
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
    video_params = MediaInfoExtractor.extract_video_params(validated_mediainfo, path)
    {:ok, video_params}
  rescue
    e ->
      Logger.error("Failed to extract video params for #{path}: #{inspect(e)}")
      {:error, "video parameter extraction failed"}
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
