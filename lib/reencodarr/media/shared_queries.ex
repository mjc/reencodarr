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
      where: v.state != :failed,
      left_join: m_all in Vmaf,
      on: m_all.video_id == v.id,
      select: %{
        not_reencoded: fragment("COUNT(*) FILTER (WHERE ? != 'encoded')", v.state),
        reencoded: fragment("COUNT(*) FILTER (WHERE ? = 'encoded')", v.state),
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
        queued_crf_searches_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IS NULL AND ? = 'analyzed')",
            m_all.id,
            v.state
          ),
        analyzer_count: fragment("COUNT(*) FILTER (WHERE ? = 'needs_analysis')", v.state),
        most_recent_video_update: max(v.updated_at),
        most_recent_inserted_video: max(v.inserted_at)
      }
  end
end
