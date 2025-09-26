defmodule Reencodarr.Analyzer.Optimization.BulkFileChecker do
  @moduledoc """
  Optimized bulk file existence checking for RAID arrays.

  Uses parallel stat() calls to efficiently check file existence
  for large batches, optimized for high-performance storage.
  """

  require Logger
  alias Reencodarr.Analyzer.Core.ConcurrencyManager

  @doc """
  Check file existence for a batch of paths in parallel.

  Returns a map of path -> boolean for existence status.
  Optimized for RAID arrays with high I/O concurrency.
  """
  @spec check_files_exist([String.t()]) :: %{String.t() => boolean()}
  def check_files_exist(paths) when is_list(paths) do
    # Use storage-aware concurrency for file checks
    concurrency = get_optimal_file_check_concurrency(length(paths))

    Logger.debug("Checking #{length(paths)} files with concurrency #{concurrency}")

    paths
    |> Task.async_stream(
      &check_single_file_optimized/1,
      max_concurrency: concurrency,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {path, exists}}, acc -> Map.put(acc, path, exists)
      # Skip timed out files
      {:exit, :timeout}, acc -> acc
      _, acc -> acc
    end)
  end

  defp check_single_file_optimized(path) do
    exists = File.exists?(path)
    {path, exists}
  end

  defp get_optimal_file_check_concurrency(file_count) when file_count <= 10, do: file_count
  defp get_optimal_file_check_concurrency(file_count) when file_count <= 50, do: 20

  defp get_optimal_file_check_concurrency(_file_count) do
    # For RAIDZ3 with 9 disks, we can handle high I/O concurrency
    # Use video processing concurrency as a proxy for storage performance
    video_concurrency =
      ConcurrencyManager.get_video_processing_concurrency()

    # Scale file check concurrency based on video processing capability
    case video_concurrency do
      # Ultra-high performance storage
      c when c >= 32 -> 50
      # High performance storage
      c when c >= 16 -> 30
      # Standard storage
      c when c >= 8 -> 15
      # Conservative default
      _ -> 10
    end
  end
end
