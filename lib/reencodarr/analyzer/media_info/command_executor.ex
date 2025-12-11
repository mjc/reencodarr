defmodule Reencodarr.Analyzer.MediaInfo.CommandExecutor do
  @moduledoc """
  Consolidated MediaInfo command execution with optimized performance for high-throughput storage.

  This module eliminates duplication by centralizing all MediaInfo command execution,
  JSON parsing, and result processing in one place.

  Features:
  - Batch command execution with configurable sizes
  - Concurrent chunk processing for large batches
  - Intelligent fallback strategies
  - Comprehensive error handling
  - Performance monitoring integration
  """

  require Logger

  alias Reencodarr.Analyzer.{
    Broadway.PerformanceMonitor,
    Core.ConcurrencyManager,
    Optimization.BulkFileChecker
  }

  @doc """
  Execute MediaInfo command for a batch of file paths.

  Automatically optimizes batch size and concurrency based on system capabilities.
  """
  @spec execute_batch_mediainfo([String.t()]) :: {:ok, map()} | {:error, term()}
  def execute_batch_mediainfo([_ | _] = paths) do
    Logger.debug("Executing MediaInfo for #{length(paths)} files")

    # Pre-filter existing files to avoid command errors
    valid_paths = filter_existing_files(paths)

    case valid_paths do
      [] ->
        Logger.debug("No valid files found for MediaInfo execution")
        {:ok, %{}}

      files ->
        execute_optimized_batch(files)
    end
  end

  def execute_batch_mediainfo([]), do: {:ok, %{}}

  @doc """
  Execute MediaInfo command for a single file.
  """
  @spec execute_single_mediainfo(String.t()) :: {:ok, map()} | {:error, term()}
  def execute_single_mediainfo(path) when is_binary(path) do
    case File.exists?(path) do
      true -> execute_mediainfo_command([path])
      false -> {:error, "file does not exist: #{path}"}
    end
  end

  # Private functions

  defp filter_existing_files(paths) do
    BulkFileChecker.check_files_exist(paths)
    |> Enum.filter(fn {_path, exists} -> exists end)
    |> Enum.map(fn {path, _exists} -> path end)
  end

  defp execute_optimized_batch(paths) do
    batch_size = get_optimal_batch_size(length(paths))

    case length(paths) do
      count when count <= batch_size ->
        # Small batch - execute directly
        execute_mediainfo_command(paths)

      _large_count ->
        # Large batch - use chunked processing
        execute_chunked_mediainfo(paths, batch_size)
    end
  end

  defp execute_chunked_mediainfo(paths, batch_size) do
    chunk_concurrency = get_chunk_concurrency(length(paths))

    Logger.debug(
      "Processing #{length(paths)} files in chunks of #{batch_size} with concurrency #{chunk_concurrency}"
    )

    paths
    |> Enum.chunk_every(batch_size)
    |> Task.async_stream(
      &execute_mediainfo_command/1,
      max_concurrency: chunk_concurrency,
      timeout: :timer.minutes(5),
      on_timeout: :kill_task
    )
    |> merge_chunk_results()
  end

  defp execute_mediainfo_command(paths) when is_list(paths) do
    Logger.debug("Executing mediainfo command for #{length(paths)} files")

    start_time = System.monotonic_time(:millisecond)
    args = build_mediainfo_args(paths)

    case System.cmd("mediainfo", args, stderr_to_stdout: true) do
      {json, 0} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.debug("MediaInfo completed #{length(paths)} files in #{duration}ms")

        # Record batch processing time for performance monitoring
        PerformanceMonitor.record_mediainfo_batch(
          length(paths),
          duration
        )

        parse_mediainfo_json(json, paths)

      {error_msg, code} ->
        Logger.error("MediaInfo command failed with code #{code}: #{error_msg}")
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp build_mediainfo_args(paths) do
    # Optimized MediaInfo arguments for best performance
    base_args = [
      "--Output=JSON",
      # Suppress log output for cleaner execution
      "--LogFile=/dev/null",
      # Get complete information
      "--Full"
    ]

    base_args ++ paths
  end

  defp parse_mediainfo_json(json, paths) do
    case Jason.decode(json) do
      {:ok, data} ->
        process_mediainfo_data(data, paths)

      {:error, reason} ->
        Logger.error("JSON decode failed for #{length(paths)} files: #{inspect(reason)}")
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp process_mediainfo_data(data, _paths) when is_list(data) do
    # Multiple media objects (batch processing)
    Logger.debug("Processing MediaInfo batch with #{length(data)} media objects")

    result_map =
      data
      |> Enum.reduce(%{}, &process_single_media_object/2)

    {:ok, result_map}
  end

  defp process_mediainfo_data(data, [single_path] = _paths) when is_map(data) do
    # Single media object or flat structure
    case data do
      %{"media" => _media_item} ->
        Logger.debug("Processing single MediaInfo object")
        result_map = process_single_media_object(data, %{})
        {:ok, result_map}

      flat_data when is_map(flat_data) ->
        Logger.debug("Processing flat MediaInfo structure")
        # Convert flat structure to proper format
        wrapped_data = %{"media" => flat_data}
        {:ok, %{single_path => wrapped_data}}

      _ ->
        {:error, "unexpected MediaInfo JSON structure"}
    end
  end

  defp process_mediainfo_data(data, paths) do
    Logger.error(
      "Unexpected MediaInfo JSON structure for #{length(paths)} paths: #{inspect(data, limit: 100)}"
    )

    {:error, "unexpected MediaInfo JSON structure"}
  end

  defp process_single_media_object(%{"media" => media_item} = media_data, acc) do
    case extract_file_path(media_item) do
      {:ok, path} ->
        Map.put(acc, path, media_data)

      {:error, reason} ->
        Logger.warning("Failed to extract file path from MediaInfo: #{reason}")
        acc
    end
  end

  defp process_single_media_object(invalid_data, acc) do
    Logger.warning("Invalid MediaInfo structure: #{inspect(invalid_data, limit: 50)}")
    acc
  end

  defp extract_file_path(%{"@ref" => path}) when is_binary(path), do: {:ok, path}

  defp extract_file_path(%{"track" => tracks}) when is_list(tracks) do
    case find_general_track(tracks) do
      %{"CompleteName" => path} when is_binary(path) -> {:ok, path}
      _ -> {:error, "no complete name found in general track"}
    end
  end

  defp extract_file_path(_media_item) do
    {:error, "unable to extract file path from media item"}
  end

  defp find_general_track(tracks) when is_list(tracks) do
    Enum.find(tracks, %{}, fn track ->
      Map.get(track, "@type") == "General"
    end)
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
        Logger.error("Chunk task timeout: #{inspect(reason)}")
        {:error, {:task_timeout, reason}}

      error, _ ->
        Logger.error("Unexpected chunk error: #{inspect(error)}")
        {:error, error}
    end)
  end

  defp get_optimal_batch_size(file_count) do
    # Get the current optimal batch size from performance systems
    base_batch_size =
      case Process.whereis(PerformanceMonitor) do
        nil ->
          ConcurrencyManager.get_optimal_mediainfo_batch_size()

        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            PerformanceMonitor.get_current_mediainfo_batch_size()
          else
            ConcurrencyManager.get_optimal_mediainfo_batch_size()
          end

        _ ->
          ConcurrencyManager.get_optimal_mediainfo_batch_size()
      end

    # Don't exceed the number of files we actually have
    min(base_batch_size, file_count)
  end

  defp get_chunk_concurrency(total_files) do
    cond do
      # Small batch - single process
      total_files < 50 ->
        1

      # Medium batch - 2 processes
      total_files < 200 ->
        2

      # Large batch - scale with system capability
      true ->
        video_concurrency = ConcurrencyManager.get_video_processing_concurrency()

        # Conservative scaling for MediaInfo processes
        case video_concurrency do
          # Ultra-high performance: 4 concurrent processes
          c when c >= 32 -> 4
          # High performance: 3 processes
          c when c >= 16 -> 3
          # Standard: 2 processes
          c when c >= 8 -> 2
          # Conservative: single process
          _ -> 1
        end
    end
  end
end
