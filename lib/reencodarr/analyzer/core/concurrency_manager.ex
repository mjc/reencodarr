defmodule Reencodarr.Analyzer.Core.ConcurrencyManager do
  @moduledoc """
  Manages dynamic concurrency settings for analyzer operations.

  Automatically adjusts concurrency based on system load, memory usage,
  and performance metrics to optimize throughput while preventing resource exhaustion.
  """

  require Logger

  @system_concurrency_base 4
  @memory_threshold_mb 1000
  @load_threshold 0.8
  @min_concurrency 2
  @max_concurrency 16

  # High-performance storage specific settings (only applied after detection)
  @high_perf_min_concurrency 4
  @high_perf_max_concurrency 32
  @ultra_high_perf_max_concurrency 64

  @doc """
  Get optimal concurrency level for video processing tasks.

  Takes into account:
  - Available CPU cores
  - Current system load
  - Available memory
  - Recent performance metrics
  - Storage performance tier for RAID optimization
  """
  @spec get_video_processing_concurrency() :: pos_integer()
  def get_video_processing_concurrency do
    base_concurrency = get_base_concurrency()
    system_adjusted = adjust_for_system_load(base_concurrency)
    memory_adjusted = adjust_for_memory_usage(system_adjusted)
    storage_adjusted = adjust_for_storage_performance(memory_adjusted)

    final_concurrency =
      storage_adjusted
      |> max(get_min_concurrency())
      |> min(get_max_concurrency())

    Logger.debug(
      "ConcurrencyManager: Using #{final_concurrency} concurrency " <>
        "(base: #{base_concurrency}, system: #{system_adjusted}, memory: #{memory_adjusted}, storage: #{storage_adjusted})"
    )

    final_concurrency
  end

  @doc """
  Get optimal concurrency for mediainfo operations.
  For high-performance storage, allows higher concurrency for I/O intensive operations.
  """
  @spec get_mediainfo_concurrency() :: pos_integer()
  def get_mediainfo_concurrency do
    video_concurrency = get_video_processing_concurrency()
    storage_tier = get_storage_performance_tier()

    # For high-performance storage, mediainfo can benefit from higher concurrency
    # since sequential I/O performance scales well with RAID arrays
    mediainfo_concurrency = case storage_tier do
      :ultra_high_performance ->
        # Ultra high-performance storage can handle much higher concurrency
        min(video_concurrency, 16)

      :high_performance ->
        # High-performance storage benefits from higher concurrency
        min(video_concurrency, 12)

      _ ->
        # Standard storage - conservative concurrency for I/O bound operations
        max(2, div(video_concurrency, 2))
    end

    max(2, mediainfo_concurrency)
  end

  @doc """
  Get timeout for video processing tasks based on system performance.
  """
  @spec get_processing_timeout() :: pos_integer()
  def get_processing_timeout do
    # Base timeout of 2 minutes, adjusted for system load
    base_timeout = :timer.minutes(2)

    case get_system_load_average() do
      load when load > 2.0 ->
        # High load - increase timeout
        round(base_timeout * 1.5)

      load when load > 1.0 ->
        # Medium load - slight increase
        round(base_timeout * 1.2)

      _ ->
        # Low load - use base timeout
        base_timeout
    end
  end

  @doc """
  Get optimal MediaInfo batch size for detected storage performance.
  Starts conservative for single drives, scales up for RAID arrays.
  """
  @spec get_optimal_mediainfo_batch_size() :: pos_integer()
  def get_optimal_mediainfo_batch_size do
    storage_tier = get_storage_performance_tier()

    case storage_tier do
      :ultra_high_performance ->
        # Ultra high-performance storage (>1GB/s) - large batches for optimal sequential I/O
        100

      :high_performance ->
        # High-performance storage (>500MB/s) - moderate batches
        50

      :standard ->
        # Standard storage - conservative batches to avoid overwhelming single drives
        15

      :unknown ->
        # Unknown performance - very conservative until we detect capabilities
        8
    end
  end  # Private functions

  defp get_base_concurrency do
    # Start with number of CPU cores with higher base for high-performance systems
    cpu_cores = System.schedulers_online()
    base = max(@system_concurrency_base, cpu_cores)

    # Scale up for high-core-count systems (common with RAID setups)
    if cpu_cores >= 16 do
      round(base * 1.5)
    else
      base
    end
  end

  defp get_storage_performance_tier do
    Reencodarr.Analyzer.Broadway.PerformanceMonitor.get_storage_performance_tier()
  end

  defp get_min_concurrency do
    case get_storage_performance_tier() do
      tier when tier in [:ultra_high_performance, :high_performance] -> @high_perf_min_concurrency
      _ -> @min_concurrency
    end
  end

  defp get_max_concurrency do
    case get_storage_performance_tier() do
      :ultra_high_performance -> @ultra_high_perf_max_concurrency
      :high_performance -> @high_perf_max_concurrency
      _ -> @max_concurrency
    end
  end

  defp adjust_for_storage_performance(concurrency) do
    storage_tier = get_storage_performance_tier()

    case storage_tier do
      :ultra_high_performance ->
        # RAID arrays with >1GB/s capability - scale up aggressively only after detection
        round(concurrency * 2.5)

      :high_performance ->
        # High-performance storage - moderate scaling after detection
        round(concurrency * 1.8)

      :standard ->
        # Standard storage - small scaling to avoid overwhelming single drives
        round(concurrency * 1.2)

      :unknown ->
        # Unknown storage - no scaling until we know performance characteristics
        concurrency
    end
  end

  defp adjust_for_system_load(base_concurrency) do
    case get_system_load_average() do
      load when load > @load_threshold ->
        # High load - reduce concurrency
        reduction_factor = min(0.5, @load_threshold / load)
        max(2, round(base_concurrency * reduction_factor))

      _ ->
        base_concurrency
    end
  end

  defp adjust_for_memory_usage(concurrency) do
    case get_available_memory_mb() do
      memory_mb when memory_mb < @memory_threshold_mb ->
        # Low memory - reduce concurrency significantly
        max(2, div(concurrency, 2))

      memory_mb when memory_mb < @memory_threshold_mb * 2 ->
        # Medium memory - slight reduction
        max(2, round(concurrency * 0.8))

      _ ->
        # Plenty of memory - no reduction
        concurrency
    end
  end

  defp get_system_load_average do
    # Try to get 1-minute load average on Linux systems
    case System.cmd("uptime", []) do
      {output, 0} ->
        parse_load_from_uptime(output)

      _ ->
        # Fallback - assume moderate load
        1.0
    end
  rescue
    _ -> 1.0
  end

  defp parse_load_from_uptime(output) do
    # Parse load average from uptime output
    # Example: "... load average: 0.52, 0.48, 0.47"
    case Regex.run(~r/load average: ([\d.]+)/, output) do
      [_, load_str] ->
        parse_load_string(load_str)

      _ ->
        1.0
    end
  end

  defp parse_load_string(load_str) do
    case Float.parse(load_str) do
      {load, ""} -> load
      _ -> 1.0
    end
  end

  defp get_available_memory_mb do
    # Try to get available memory on Linux systems
    case System.cmd("free", ["-m"]) do
      {output, 0} ->
        parse_memory_from_free(output)

      _ ->
        # Fallback - assume plenty of memory
        @memory_threshold_mb * 2
    end
  rescue
    _ -> @memory_threshold_mb * 2
  end

  defp parse_memory_from_free(output) do
    # Parse available memory from free -m output
    # Look for "available" column in newer versions, fall back to free memory
    case Regex.run(~r/Mem:\s+\d+\s+\d+\s+(\d+)/, output) do
      [_, available_str] ->
        parse_memory_string(available_str)

      _ ->
        @memory_threshold_mb * 2
    end
  end

  defp parse_memory_string(available_str) do
    case Integer.parse(available_str) do
      {available_mb, ""} -> available_mb
      _ -> @memory_threshold_mb * 2
    end
  end
end
