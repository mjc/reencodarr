defmodule Reencodarr.Media.Statistics do
  @moduledoc """
  Media domain statistics and aggregation queries.

  This module provides database-level statistics queries for the Media context.
  It focuses purely on data aggregation from media entities (Videos, VMAFs, etc.)
  without external dependencies or business logic concerns.

  Used by the main Statistics GenServer for dashboard and monitoring purposes.
  """

  import Ecto.Query
  alias Reencodarr.Media.{Video, Vmaf}
  alias Reencodarr.Repo
  alias Reencodarr.Statistics.Stats
  require Logger

  @doc """
  Fetches comprehensive statistics for the dashboard.

  Returns aggregated statistics from media entities without external dependencies.
  Used by the main Statistics GenServer to build complete dashboard state.
  """
  @spec fetch_media_stats() :: Stats.t()
  def fetch_media_stats do
    case Repo.transaction(fn -> Repo.one(aggregated_stats_query()) end) do
      {:ok, stats} ->
        build_stats(stats)

      {:error, _} ->
        Logger.error("Failed to fetch media stats")
        build_empty_stats()
    end
  end

  @doc """
  Gets the most recent video update timestamp.
  """
  @spec most_recent_video_update() :: DateTime.t() | nil
  def most_recent_video_update do
    Repo.one(from v in Video, select: max(v.updated_at))
  end

  @doc """
  Gets the most recent video insertion timestamp.
  """
  @spec get_most_recent_inserted_at() :: DateTime.t() | nil
  def get_most_recent_inserted_at do
    Repo.one(from v in Video, select: max(v.inserted_at))
  end

  @doc """
  Gets the next video for encoding ordered by time.
  """
  @spec get_next_for_encoding_by_time() :: Vmaf.t() | nil
  def get_next_for_encoding_by_time do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.state == :crf_searched,
        order_by: [fragment("? DESC NULLS LAST", v.savings), asc: v.time],
        limit: 1,
        preload: [:video]
    )
  end

  # Build full stats struct on successful DB query
  defp build_stats(stats) do
    next_encoding_by_time = get_next_for_encoding_by_time()

    %Stats{
      avg_vmaf_percentage: stats.avg_vmaf_percentage,
      chosen_vmafs_count: stats.chosen_vmafs_count,
      lowest_vmaf_by_time_seconds: next_encoding_by_time && next_encoding_by_time.time,
      not_reencoded: stats.not_reencoded,
      reencoded: stats.reencoded,
      total_videos: stats.total_videos,
      total_vmafs: stats.total_vmafs,
      most_recent_video_update: stats.most_recent_video_update,
      most_recent_inserted_video: stats.most_recent_inserted_video,
      queue_length: %{
        encodes: stats.encodes_count,
        crf_searches: stats.queued_crf_searches_count,
        analyzer: stats.analyzer_count
      }
    }
  end

  # Build minimal stats struct when DB query fails
  defp build_empty_stats do
    %Stats{
      most_recent_video_update: most_recent_video_update(),
      most_recent_inserted_video: get_most_recent_inserted_at()
    }
  end

  defp aggregated_stats_query do
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
