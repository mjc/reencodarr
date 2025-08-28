defmodule Reencodarr.Media.SharedQueries do
  @moduledoc """
  Shared query functions used by multiple Media context modules.

  Eliminates duplication of complex database queries across
  the Media context while maintaining proper separation of concerns.
  """

  import Ecto.Query
  alias Reencodarr.Media.{Video, Vmaf}

  # Helper to check database adapter
  defp sqlite? do
    # Check the adapter via the Repo's __adapter__ function
    Reencodarr.Repo.__adapter__() == Ecto.Adapters.SQLite3
  end

  @doc """
  Database-agnostic query to find video IDs with no chosen VMAFs.
  Used by delete_unchosen_vmafs functions.
  """
  def videos_with_no_chosen_vmafs_query do
    if sqlite?() do
      from(v in Vmaf,
        group_by: v.video_id,
        having: fragment("SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END) = 0", v.chosen),
        select: v.video_id
      )
    else
      from(v in Vmaf,
        group_by: v.video_id,
        having: fragment("COUNT(*) FILTER (WHERE ? = true) = 0", v.chosen),
        select: v.video_id
      )
    end
  end

  @doc """
  Aggregated statistics query used by both Media and Media.Statistics modules.

  Returns comprehensive video statistics including counts, averages, and timestamps.
  This query is used identically in multiple modules, so it's consolidated here.
  """
  def aggregated_stats_query do
    # Check if we're using SQLite
    if sqlite?() do
      sqlite_aggregated_stats_query()
    else
      postgres_aggregated_stats_query()
    end
  end

  # PostgreSQL version with FILTER syntax
  defp postgres_aggregated_stats_query do
    from v in Video,
      where: v.state not in [:failed],
      left_join: m_all in Vmaf,
      on: m_all.video_id == v.id,
      select: %{
        total_videos: count(v.id),
        avg_vmaf_percentage: fragment("ROUND(AVG(?)::numeric, 2)", m_all.percent),
        total_vmafs: count(m_all.id),
        chosen_vmafs_count: fragment("COUNT(*) FILTER (WHERE ? = true)", m_all.chosen),
        encodes_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? = 'crf_searched' AND ? = true)",
            v.state,
            m_all.chosen
          ),
        queued_crf_searches_count: fragment("COUNT(*) FILTER (WHERE ? = 'analyzed')", v.state),
        analyzer_count: fragment("COUNT(*) FILTER (WHERE ? = 'needs_analysis')", v.state),
        most_recent_video_update: max(v.updated_at),
        most_recent_inserted_video: max(v.inserted_at),
        # State-based fields for dashboard (using correct enum atoms)
        reencoded_count: filter(count(v.id), v.state == :encoded),
        failed_count: filter(count(v.id), v.state == :failed),
        analyzing_count: filter(count(v.id), v.state == :needs_analysis),
        encoding_count: filter(count(v.id), v.state == :encoding),
        searching_count: filter(count(v.id), v.state == :crf_searching),
        available_count: filter(count(v.id), v.state == :crf_searched),
        # No paused state in enum
        paused_count: fragment("0"),
        # No skipped state in enum
        skipped_count: fragment("0"),
        # Total savings calculation
        total_savings_gb:
          coalesce(
            sum(
              fragment(
                "CASE WHEN ? = true AND ? > 0 THEN ?::bigint::decimal / 1073741824 ELSE 0 END",
                m_all.chosen,
                m_all.savings,
                m_all.savings
              )
            ),
            0
          )
      }
  end

  # SQLite version without FILTER syntax and type casting
  defp sqlite_aggregated_stats_query do
    from v in Video,
      # Use ^ to interpolate the atom list
      where: v.state not in ^[:failed],
      left_join: m_all in Vmaf,
      on: m_all.video_id == v.id,
      select: %{
        total_videos: count(v.id),
        avg_vmaf_percentage: fragment("ROUND(AVG(?), 2)", m_all.percent),
        total_vmafs: count(m_all.id),
        chosen_vmafs_count:
          fragment("COALESCE(SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END), 0)", m_all.chosen),
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
        most_recent_video_update: max(v.updated_at),
        most_recent_inserted_video: max(v.inserted_at),
        # State-based fields for dashboard (using atom values since Ecto.Enum handles the conversion)
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
        # No paused state in enum
        paused_count: fragment("0"),
        # No skipped state in enum
        skipped_count: fragment("0"),
        # Total savings calculation (without type casting)
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
          )
      }
  end
end
