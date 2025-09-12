defmodule Reencodarr.Media.SharedQueries do
  @moduledoc """
  Shared query functions used by multiple Media context modules.

  Eliminates duplication of complex database queries across
  the Media context while maintaining proper separation of concerns.
  """

  import Ecto.Query
  alias Reencodarr.Media.{Video, Vmaf}

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
  def videos_not_matching_exclude_patterns(video_list) when length(video_list) < 50 do
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

  # Helper for pattern matching with basic glob support
  defp matches_pattern?(path, pattern) do
    # Convert glob pattern to regex
    # Supports: * (any characters), ** (directory traversal), ? (single character)
    regex_pattern =
      pattern
      # Temporary placeholder
      |> String.replace("**", "__DOUBLE_STAR__")
      |> Regex.escape()
      # ** matches any path including /
      |> String.replace("__DOUBLE_STAR__", ".*")
      # * matches any characters except /
      |> String.replace("\\*", "[^/]*")
      # ? matches single character
      |> String.replace("\\?", ".")
      # Anchor to full string
      |> then(&("^" <> &1 <> "$"))

    case Regex.compile(regex_pattern, [:caseless]) do
      {:ok, regex} ->
        Regex.match?(regex, path)

      {:error, _} ->
        # Fallback to simple string matching if regex compilation fails
        String.contains?(String.downcase(path), String.downcase(pattern))
    end
  end

  # Database filtering for large lists (placeholder for future optimization)
  defp filter_large_video_list_by_patterns(video_list) do
    # For now, fall back to memory filtering
    # Future: implement database-side filtering with SQL patterns
    patterns = Reencodarr.Config.exclude_patterns()
    filter_videos_by_patterns(video_list, patterns)
  end

  @doc """
  Get all unique video states from the database.

  Used by various dashboard and filtering components to present
  consistent state options to users.
  """
  def get_all_video_states do
    from(v in Video,
      select: v.state,
      distinct: true,
      order_by: v.state
    )
    |> Reencodarr.Repo.all()
  end

  @doc """
  Find videos that are candidates for retry operations.

  Returns videos in failed state that haven't exceeded the retry limit
  and aren't in an indefinite failure state.
  """
  def retry_candidate_videos(limit \\ 100) do
    from(v in Video,
      where: v.state == :failed,
      # Configurable retry limit
      where: v.retry_count < 3,
      order_by: [desc: v.updated_at],
      limit: ^limit
    )
  end

  @doc """
  Complex query to find videos with optimal encoding characteristics.

  Returns videos that are good candidates for immediate encoding based on:
  - File size vs quality metrics
  - Available CRF search results
  - System capacity
  """
  def optimal_encoding_candidates(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    min_file_size = Keyword.get(opts, :min_file_size_mb, 100)

    # Convert MB to bytes for comparison
    min_size_bytes = min_file_size * 1024 * 1024

    from(v in Video,
      left_join: vmaf in Vmaf,
      on: v.id == vmaf.video_id,
      where: v.state == :crf_searched,
      where: v.size > ^min_size_bytes,
      where: not is_nil(vmaf.crf),
      select: %{
        video: v,
        vmaf_score: vmaf.score,
        crf: vmaf.crf,
        compression_ratio:
          fragment(
            "CAST(? AS FLOAT) / CAST(? AS FLOAT)",
            v.size,
            v.size
          ),
        priority_score:
          fragment(
            """
              (CAST(? AS FLOAT) / 1000000.0) *  -- File size in MB
              (CASE
                WHEN ? > 95 THEN 1.5  -- High VMAF bonus
                WHEN ? > 90 THEN 1.2  -- Medium VMAF bonus
                ELSE 1.0
              END) *
              (CASE
                WHEN CAST(? AS FLOAT) / CAST(? AS FLOAT) > 2.0 THEN 2.0  -- High compression potential
                WHEN CAST(? AS FLOAT) / CAST(? AS FLOAT) > 1.5 THEN 1.5  -- Medium compression
                ELSE 1.0
              END)
            """,
            v.size,
            vmaf.score,
            vmaf.score,
            v.size,
            v.size,
            v.size,
            v.size
          )
      },
      order_by: [desc: fragment("priority_score")],
      limit: ^limit
    )
  end

  @doc """
  Get storage statistics across video states for dashboard display.

  Returns aggregated storage usage information grouped by video processing state.
  """
  def storage_stats_by_state do
    from(v in Video,
      group_by: v.state,
      select: %{
        state: v.state,
        count: count(v.id),
        total_size_gb: fragment("ROUND(CAST(SUM(?) AS FLOAT) / 1073741824.0, 2)", v.size),
        avg_size_mb: fragment("ROUND(CAST(AVG(?) AS FLOAT) / 1048576.0, 2)", v.size),
        largest_file_gb: fragment("ROUND(CAST(MAX(?) AS FLOAT) / 1073741824.0, 2)", v.size)
      },
      order_by: [desc: fragment("total_size_gb")]
    )
  end

  @doc """
  Find duplicate videos based on file size and duration.

  Helps identify potential duplicate content that may have been
  imported from multiple sources or with slight variations.
  """
  def potential_duplicate_videos(tolerance_percent \\ 5) do
    # Calculate size tolerance (e.g., 5% difference)
    size_tolerance_query = """
    WITH size_groups AS (
      SELECT
        size,
        duration,
        ARRAY_AGG(id) as video_ids,
        COUNT(*) as group_size
      FROM videos
      WHERE size IS NOT NULL
        AND duration IS NOT NULL
      GROUP BY size, duration
      HAVING COUNT(*) > 1
    ),
    tolerance_groups AS (
      SELECT DISTINCT
        v1.id as video1_id,
        v2.id as video2_id,
        v1.path as path1,
        v2.path as path2,
        v1.size as size1,
        v2.size as size2,
        ABS(v1.size - v2.size) as size_diff,
        ABS(v1.duration - v2.duration) as duration_diff
      FROM videos v1
      JOIN videos v2 ON v1.id < v2.id
      WHERE v1.size IS NOT NULL
        AND v2.size IS NOT NULL
        AND v1.duration IS NOT NULL
        AND v2.duration IS NOT NULL
        AND ABS(v1.size - v2.size) <= (GREATEST(v1.size, v2.size) * #{tolerance_percent} / 100)
        AND ABS(v1.duration - v2.duration) <= 60  -- Within 1 minute
    )
    SELECT * FROM tolerance_groups
    ORDER BY size_diff ASC
    """

    Reencodarr.Repo.query(size_tolerance_query)
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
