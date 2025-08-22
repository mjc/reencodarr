defmodule Reencodarr.Media.SharedQueries do
  @moduledoc """
  Shared query functions used by multiple Media context modules.

  Eliminates duplication of complex database queries across
  the Media context while maintaining proper separation of concerns.
  """

  import Ecto.Query
  alias Reencodarr.Media.{Video, Vmaf}

  @doc """
  Aggregated statistics query used by both Media and Media.Statistics modules.

  Returns comprehensive video statistics including counts, averages, and timestamps.
  This query is used identically in multiple modules, so it's consolidated here.
  """
  def aggregated_stats_query do
    from v in Video,
      where: v.failed == false,
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
        paused_count: fragment("0"), # No paused state in enum
        skipped_count: fragment("0"), # No skipped state in enum
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
end
