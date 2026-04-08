defmodule Reencodarr.Media.SharedQueries do
  @moduledoc """
  Shared query functions used by multiple Media context modules.

  Eliminates duplication of complex database queries across
  the Media context while maintaining proper separation of concerns.
  """

  import Ecto.Query
  alias Reencodarr.Media.{DashboardStatsCache, GlobPattern, Video, Vmaf}

  # Configuration constants
  @large_list_threshold 50

  @doc """
  Database-agnostic case-insensitive LIKE operation.
  SQLite uses LIKE with UPPER().
  Returns a dynamic query fragment that can be used in where clauses.
  """
  def case_insensitive_like(field, pattern) do
    # SQLite: Use LIKE with UPPER() on both sides
    dynamic([q], fragment("UPPER(?) LIKE UPPER(?)", field(q, ^field), ^pattern))
  end

  @doc """
  List videos that don't match exclude patterns from given list.

  Optimized with early pattern matching.
  """
  def videos_not_matching_exclude_patterns(video_list)
      when length(video_list) < @large_list_threshold do
    patterns = Reencodarr.Config.exclude_patterns()

    case patterns do
      [] -> video_list
      patterns -> filter_videos_by_patterns(video_list, patterns)
    end
  end

  def videos_not_matching_exclude_patterns(video_list) do
    # For large lists, use database filtering for better performance
    filter_large_video_list_by_patterns(video_list)
  end

  # Pattern matching for smaller video lists
  defp filter_videos_by_patterns(videos, patterns) do
    Enum.filter(videos, fn video ->
      not Enum.any?(patterns, &matches_pattern?(video.path, &1))
    end)
  end

  # Helper for pattern matching with structured glob support
  defp matches_pattern?(path, pattern) do
    GlobPattern.new(pattern) |> GlobPattern.matches?(path)
  end

  # Database filtering for large lists (placeholder for future optimization)
  defp filter_large_video_list_by_patterns(video_list) do
    # For now, fall back to memory filtering
    # Future: implement database-side filtering with SQL patterns
    patterns = Reencodarr.Config.exclude_patterns()
    filter_videos_by_patterns(video_list, patterns)
  end

  @doc """
  Query to find video IDs that have VMAF records but no chosen VMAF.
  Used by delete_unchosen_vmafs functions.
  """
  def videos_with_no_chosen_vmafs_query do
    from(v in Video,
      join: vm in Vmaf,
      on: vm.video_id == v.id,
      where: is_nil(v.chosen_vmaf_id),
      group_by: v.id,
      select: v.id
    )
  end

  @doc """
  Single-table query for video statistics (no join).

  Returns state counts, size, and duration aggregates from the videos table only.
  Combine with `vmaf_stats_query/0` via `Map.merge/2` for full dashboard stats.

  Savings calculation uses actual data (original_size - size) for encoded videos
  and falls back to predicted savings from chosen VMAFs for not-yet-encoded videos.
  """
  def video_stats_query do
    from c in dashboard_stats_cache_query(),
      select: %{
        total_videos: c.total_videos,
        total_size_gb:
          fragment("ROUND(CAST(? AS FLOAT) / (1024*1024*1024), 2)", c.total_size_bytes),
        needs_analysis: c.needs_analysis,
        analyzed: c.analyzed,
        crf_searching: c.crf_searching,
        crf_searched: c.crf_searched,
        encoding: c.encoding,
        encoded: c.encoded,
        failed: c.failed,
        avg_duration_minutes:
          fragment(
            "CASE WHEN ? > 0 THEN ROUND(CAST(? AS FLOAT) / ? / 60.0, 1) ELSE 0.0 END",
            c.duration_count,
            c.total_duration_seconds,
            c.duration_count
          ),
        most_recent_video_update: c.most_recent_video_update,
        most_recent_inserted_video: c.most_recent_inserted_video,
        total_savings_gb: 0.0
      }
  end

  @doc """
  Actual savings query for already-encoded videos.
  """
  def encoded_video_savings_query do
    from c in dashboard_stats_cache_query(),
      select: %{
        total_savings_gb: fragment("CAST(? AS FLOAT) / 1073741824.0", c.encoded_savings_bytes)
      }
  end

  @doc """
  Predicted savings query for videos with a chosen VMAF that are not yet encoded.
  """
  def predicted_video_savings_query do
    from c in dashboard_stats_cache_query(),
      select: %{
        total_savings_gb: fragment("CAST(? AS FLOAT) / 1073741824.0", c.predicted_savings_bytes)
      }
  end

  @doc """
  VMAF statistics query.

  Returns VMAF counts from the vmafs and videos tables.
  Combine with `video_stats_query/0` via `Map.merge/2` for full dashboard stats.
  Avoids expensive JOINs by counting directly on videos table.
  """
  def vmaf_stats_query do
    from c in dashboard_stats_cache_query(),
      select: %{
        total_vmafs: c.total_vmafs,
        chosen_vmafs: c.chosen_vmafs
      }
  end

  def dashboard_total_size_query do
    from c in dashboard_stats_cache_query(),
      select: fragment("ROUND(CAST(? AS FLOAT) / (1024*1024*1024), 2)", c.total_size_bytes)
  end

  defp dashboard_stats_cache_query do
    from c in DashboardStatsCache, where: c.id == 1
  end
end
