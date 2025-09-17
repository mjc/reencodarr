defmodule Reencodarr.Analyzer.ConcurrencyManager do
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

  @doc """
  Get optimal concurrency level for video processing tasks.

  Takes into account:
  - Available CPU cores
  - Current system load
  - Available memory
  - Recent performance metrics
  """
  @spec get_video_processing_concurrency() :: pos_integer()
  def get_video_processing_concurrency do
    base_concurrency = get_base_concurrency()
    system_adjusted = adjust_for_system_load(base_concurrency)
    memory_adjusted = adjust_for_memory_usage(system_adjusted)

    final_concurrency =
      memory_adjusted
      |> max(@min_concurrency)
      |> min(@max_concurrency)

    Logger.debug(
      "ConcurrencyManager: Using #{final_concurrency} concurrency " <>
        "(base: #{base_concurrency}, system: #{system_adjusted}, memory: #{memory_adjusted})"
    )

    final_concurrency
  end

  @doc """
  Get optimal concurrency for mediainfo operations.
  Lower than video processing since mediainfo is I/O intensive.
  """
  @spec get_mediainfo_concurrency() :: pos_integer()
  def get_mediainfo_concurrency do
    video_concurrency = get_video_processing_concurrency()
    # Mediainfo is I/O bound, use less concurrency
    mediainfo_concurrency = max(2, div(video_concurrency, 2))
    min(mediainfo_concurrency, 4)
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

  # Private functions

  defp get_base_concurrency do
    # Start with number of CPU cores or a minimum
    cpu_cores = System.schedulers_online()
    max(@system_concurrency_base, cpu_cores)
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
