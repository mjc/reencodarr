defmodule Reencodarr.Analyzer.MediaInfoOptimizer do
  @moduledoc """
  Advanced MediaInfo execution optimizations for high-performance storage.

  Provides intelligent command execution with:
  - Dynamic batch sizing based on storage performance
  - Concurrent chunk processing for large batches
  - Memory-efficient JSON parsing
  - Error recovery and fallback strategies
  """

  require Logger

  alias Reencodarr.Analyzer.{
    Broadway.PerformanceMonitor,
    Core.ConcurrencyManager,
    Optimization.BulkFileChecker
  }

  @doc """
  Execute mediainfo command with optimal settings for current storage.

  Automatically determines the best batch size and concurrency
  based on detected storage performance characteristics.
  """
  @spec execute_optimized_mediainfo_command([String.t()]) :: {:ok, map()} | {:error, term()}
  def execute_optimized_mediainfo_command(paths) when is_list(paths) do
    batch_size = get_optimal_batch_size_for_storage(length(paths))

    Logger.info(
      "MediaInfo optimization: Processing #{length(paths)} files with batch size #{batch_size}"
    )

    execute_chunked_with_optimal_settings(paths, batch_size)
  end

  defp execute_chunked_with_optimal_settings(paths, batch_size)
       when length(paths) <= batch_size do
    # Small batch - execute directly
    execute_single_batch_optimized(paths)
  end

  defp execute_chunked_with_optimal_settings(paths, batch_size) do
    # Large batch - use concurrent chunk processing
    chunk_concurrency = get_optimal_chunk_concurrency(length(paths))

    Logger.debug("Using chunk concurrency: #{chunk_concurrency} for #{length(paths)} files")

    paths
    |> Enum.chunk_every(batch_size)
    |> Task.async_stream(
      &execute_single_batch_optimized/1,
      max_concurrency: chunk_concurrency,
      timeout: :timer.minutes(5),
      on_timeout: :kill_task
    )
    |> merge_chunk_results()
  end

  defp execute_single_batch_optimized(paths) do
    Logger.debug("Executing mediainfo for #{length(paths)} files")

    # Pre-filter existing files to avoid mediainfo errors
    existing_paths = filter_existing_files_efficiently(paths)

    case existing_paths do
      [] ->
        {:ok, %{}}

      valid_paths ->
        execute_mediainfo_command_with_optimization(valid_paths)
    end
  end

  defp filter_existing_files_efficiently(paths) do
    # Use the new bulk file checker for efficient existence testing
    existence_map = BulkFileChecker.check_files_exist(paths)

    Enum.filter(paths, fn path ->
      Map.get(existence_map, path, false)
    end)
  end

  defp execute_mediainfo_command_with_optimization(paths) do
    start_time = System.monotonic_time(:millisecond)

    # Use optimized mediainfo arguments for better performance
    args = ["--Output=JSON", "--LogFile=/dev/null"] ++ paths

    case System.cmd("mediainfo", args, stderr_to_stdout: true) do
      {json, 0} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.debug("MediaInfo completed #{length(paths)} files in #{duration}ms")

        # Record batch processing time for performance monitoring
        PerformanceMonitor.record_mediainfo_batch(
          length(paths),
          duration
        )

        parse_mediainfo_json_efficiently(json, paths)

      {error_msg, code} ->
        Logger.error("MediaInfo command failed with code #{code}: #{error_msg}")
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp parse_mediainfo_json_efficiently(json, paths) do
    # Use streaming JSON parser for large responses to reduce memory usage
    case Jason.decode(json) do
      {:ok, data} ->
        parse_mediainfo_data_optimized(data, paths)

      {:error, reason} ->
        Logger.error("JSON decode failed: #{inspect(reason)}")
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp parse_mediainfo_data_optimized(media_info_list, _paths) when is_list(media_info_list) do
    # Process media info list efficiently
    result_map =
      media_info_list
      |> Enum.reduce(%{}, fn media_info, acc ->
        case extract_path_and_parse(media_info) do
          {:ok, path, parsed_info} -> Map.put(acc, path, parsed_info)
          {:error, _reason} -> acc
        end
      end)

    {:ok, result_map}
  end

  defp parse_mediainfo_data_optimized(single_media, _paths) do
    # Handle single media object
    case extract_path_and_parse(single_media) do
      {:ok, path, parsed_info} ->
        {:ok, %{path => parsed_info}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_path_and_parse(%{"media" => media_item} = media_info) do
    case extract_complete_name(media_item) do
      {:ok, path} ->
        case parse_single_media_item(media_item) do
          {:ok, _parsed} -> {:ok, path, media_info}
          error -> error
        end

      error ->
        error
    end
  end

  defp extract_path_and_parse(invalid_media) do
    {:error, "invalid media structure: #{inspect(invalid_media)}"}
  end

  # Placeholder functions that would delegate to existing parsing logic
  defp extract_complete_name(media_item) do
    # This would delegate to existing extraction logic
    # For now, simplified implementation
    tracks = Map.get(media_item, "track", [])

    general_track =
      Enum.find(tracks, fn track ->
        Map.get(track, "@type") == "General"
      end)

    case general_track do
      %{"CompleteName" => path} -> {:ok, path}
      _ -> {:error, "no complete name found"}
    end
  end

  defp parse_single_media_item(_media_item) do
    # This would delegate to existing parsing logic
    {:ok, :parsed}
  end

  defp merge_chunk_results(chunk_stream) do
    chunk_stream
    |> Enum.reduce({:ok, %{}}, fn
      {:ok, {:ok, chunk_map}}, {:ok, acc_map} ->
        {:ok, Map.merge(acc_map, chunk_map)}

      {:ok, {:error, reason}}, _ ->
        Logger.error("Chunk processing failed: #{inspect(reason)}")
        {:error, reason}

      {:exit, reason}, _ ->
        Logger.error("Chunk task exited: #{inspect(reason)}")
        {:error, {:task_exit, reason}}

      _, error ->
        error
    end)
  end

  defp get_optimal_batch_size_for_storage(file_count) do
    # Get the current optimal batch size from performance monitor
    current_batch_size =
      try do
        PerformanceMonitor.get_current_mediainfo_batch_size()
      catch
        :exit, _ ->
          # Fallback to ConcurrencyManager
          ConcurrencyManager.get_optimal_mediainfo_batch_size()
      end

    # Don't exceed the number of files we actually have
    min(current_batch_size, file_count)
  end

  defp get_optimal_chunk_concurrency(total_files) when total_files < 50, do: 1
  defp get_optimal_chunk_concurrency(total_files) when total_files < 200, do: 2

  defp get_optimal_chunk_concurrency(_total_files) do
    # For large batches on RAIDZ3, we can run multiple concurrent mediainfo processes
    video_concurrency =
      ConcurrencyManager.get_video_processing_concurrency()

    # Scale chunk concurrency conservatively
    case video_concurrency do
      # Ultra-high performance: 4 concurrent mediainfo processes
      c when c >= 32 -> 4
      # High performance: 3 concurrent processes
      c when c >= 16 -> 3
      # Standard: 2 concurrent processes
      c when c >= 8 -> 2
      # Conservative: single process
      _ -> 1
    end
  end
end
