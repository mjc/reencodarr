defmodule Reencodarr.Media.SharedQueries do
  @moduledoc """
  Shared query functions used by multiple Media context modules.

  Eliminates duplication of complex database queries across
  the Media context while maintaining proper separation of concerns.
  """

  import Ecto.Query
  alias Reencodarr.Media.{GlobPattern, Video, Vmaf}

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
  Database-agnostic query to find video IDs with no chosen VMAFs.
  Used by delete_unchosen_vmafs functions.
  """
  def videos_with_no_chosen_vmafs_query do
    from(v in Vmaf,
      group_by: v.video_id,
      having: fragment("SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END) = 0", v.chosen),
      select: v.video_id
    )
  end

  @doc """
  Aggregated statistics query used by both Media and Media.Statistics modules.

  Returns comprehensive video statistics including counts, averages, and timestamps.
  This query is used identically in multiple modules, so it's consolidated here.
  """
  def aggregated_stats_query do
    sqlite_aggregated_stats_query()
  end

  # SQLite version without FILTER syntax and with proper type casting
  defp sqlite_aggregated_stats_query do
    from v in Video,
      where: v.state not in ^[:failed],
      left_join: m_all in Vmaf,
      on: m_all.video_id == v.id,
      select: %{
        total_videos: count(v.id, :distinct),
        total_size_gb: fragment("ROUND(CAST(SUM(?) AS FLOAT) / (1024*1024*1024), 2)", v.size),
        needs_analysis:
          fragment("COALESCE(SUM(CASE WHEN ? = 'needs_analysis' THEN 1 ELSE 0 END), 0)", v.state),
        analyzed:
          fragment("COALESCE(SUM(CASE WHEN ? = 'analyzed' THEN 1 ELSE 0 END), 0)", v.state),
        crf_searching:
          fragment("COALESCE(SUM(CASE WHEN ? = 'crf_searching' THEN 1 ELSE 0 END), 0)", v.state),
        crf_searched:
          fragment("COALESCE(SUM(CASE WHEN ? = 'crf_searched' THEN 1 ELSE 0 END), 0)", v.state),
        encoding:
          fragment("COALESCE(SUM(CASE WHEN ? = 'encoding' THEN 1 ELSE 0 END), 0)", v.state),
        encoded: fragment("COALESCE(SUM(CASE WHEN ? = 'encoded' THEN 1 ELSE 0 END), 0)", v.state),
        failed: fragment("COALESCE(SUM(CASE WHEN ? = 'failed' THEN 1 ELSE 0 END), 0)", v.state),
        avg_duration_minutes: fragment("ROUND(AVG(CAST(? AS FLOAT)) / 60.0, 1)", v.duration),
        newest_video: max(v.inserted_at),
        oldest_video: min(v.inserted_at),
        total_vmafs: count(m_all.id, :distinct),
        chosen_vmafs:
          fragment("COALESCE(SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END), 0)", m_all.chosen),
        chosen_vmafs_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END), 0)", m_all.chosen),
        unprocessed_vmafs:
          fragment(
            "COALESCE(COUNT(DISTINCT ?) - SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END), 0)",
            m_all.id,
            m_all.chosen
          ),
        # Additional fields for dashboard compatibility
        avg_vmaf_percentage: fragment("ROUND(AVG(?), 2)", m_all.percent),
        encodes_count:
          fragment(
            "COALESCE(SUM(CASE WHEN ? = 'crf_searched' AND ? = 1 THEN 1 ELSE 0 END), 0)",
            v.state,
            m_all.chosen
          ),
        queued_crf_searches_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'analyzed' THEN 1 ELSE 0 END), 0)", v.state),
        analyzer_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'needs_analysis' THEN 1 ELSE 0 END), 0)", v.state),
        reencoded_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'encoded' THEN 1 ELSE 0 END), 0)", v.state),
        failed_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'failed' THEN 1 ELSE 0 END), 0)", v.state),
        analyzing_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'needs_analysis' THEN 1 ELSE 0 END), 0)", v.state),
        encoding_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'encoding' THEN 1 ELSE 0 END), 0)", v.state),
        searching_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'crf_searching' THEN 1 ELSE 0 END), 0)", v.state),
        available_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 'crf_searched' THEN 1 ELSE 0 END), 0)", v.state),
        paused_count: fragment("0"),
        skipped_count: fragment("0"),
        total_savings_gb:
          coalesce(
            sum(
              fragment(
                "CASE WHEN ? = 1 AND ? > 0 THEN ? / 1073741824.0 ELSE 0 END",
                m_all.chosen,
                m_all.savings,
                m_all.savings
              )
            ),
            0
          ),
        most_recent_video_update: max(v.updated_at),
        most_recent_inserted_video: max(v.inserted_at)
      }
  end
end
