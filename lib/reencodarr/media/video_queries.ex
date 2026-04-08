defmodule Reencodarr.Media.VideoQueries do
  @moduledoc """
  Centralizes complex video query logic to reduce complexity in the Media module.

  This module handles the intricate logic for alternating between services and libraries
  when selecting videos for encoding, CRF search, and analysis.
  """

  import Ecto.Query
  alias Reencodarr.{Media.DashboardQueueCache, Media.Video, Media.Vmaf, Repo}

  @doc """
  Gets videos ready for CRF search (state: analyzed).
  Excludes videos already in crf_searching state to avoid showing currently processing videos.

  ## Options
  - `:timeout` - Query timeout in milliseconds (default: 15000)
  """
  @spec videos_for_crf_search(integer(), keyword()) :: [Video.t()]
  def videos_for_crf_search(limit \\ 10, opts \\ []) do
    # Simplified query - just check state, let Rules filter codecs at encode time
    Repo.all(
      from(v in Video,
        where: v.state == :analyzed,
        order_by: [desc: v.priority, desc: v.bitrate, desc: v.size, asc: v.updated_at],
        limit: ^limit,
        select: v
      ),
      opts
    )
  end

  @doc """
  Counts the total number of videos ready for CRF search.
  Excludes videos already in crf_searching state.
  """
  @spec count_videos_for_crf_search(keyword()) :: integer()
  def count_videos_for_crf_search(opts \\ []) do
    # Simplified query - just check state, codec filtering happens at encode time
    Repo.one(
      from(v in Video,
        where: v.state == :analyzed,
        select: count()
      ),
      opts
    )
  end

  @doc """
  Gets videos needing analysis (state: needs_analysis).

  These videos lack required metadata and need MediaInfo analysis.

  ## Options
  - `:timeout` - Query timeout in milliseconds (default: 15000)
  """
  @spec videos_needing_analysis(integer(), keyword()) :: [Video.t()]
  def videos_needing_analysis(limit \\ 10, opts \\ []) do
    Repo.all(
      from(v in Video,
        where: v.state == :needs_analysis,
        order_by: [
          desc: v.priority,
          desc: v.size,
          desc: v.inserted_at,
          desc: v.updated_at
        ],
        limit: ^limit,
        select: v
      ),
      opts
    )
  end

  @doc """
  Gets a lightweight preview of videos needing analysis for dashboard display.
  """
  @spec videos_needing_analysis_preview(integer(), keyword()) :: [map()]
  def videos_needing_analysis_preview(limit \\ 10, opts \\ []),
    do: cached_dashboard_queue_preview(:analyzer, limit, opts)

  @doc """
  Atomically claims videos for analysis by transitioning them from
  `:needs_analysis` to `:analyzing`. Returns the claimed video IDs.

  This prevents race conditions where the same video could be fetched
  by multiple producer demand cycles before the batch processor
  transitions them to `:analyzed`.
  """
  @spec claim_videos_for_analysis(integer(), keyword()) :: [Video.t()]
  def claim_videos_for_analysis(limit, opts \\ []) do
    candidates =
      from(v in Video,
        where: v.state == :needs_analysis,
        order_by: [desc: v.priority, desc: v.size, desc: v.inserted_at],
        limit: ^limit,
        select: v.id
      )
      |> Repo.all(opts)

    case candidates do
      [] ->
        []

      ids ->
        {_count, claimed} =
          from(v in Video,
            where: v.id in ^ids and v.state == :needs_analysis,
            select: v
          )
          |> Repo.update_all([set: [state: :analyzing, updated_at: DateTime.utc_now()]], opts)

        claimed
    end
  end

  @doc """
  Counts the total number of videos needing analysis.
  """
  @spec count_videos_needing_analysis(keyword()) :: integer()
  def count_videos_needing_analysis(opts \\ []) do
    Repo.one(
      from(v in Video,
        where: v.state == :needs_analysis,
        select: count()
      ),
      opts
    )
  end

  @doc """
  Gets a lightweight preview of videos ready for CRF search for dashboard display.
  """
  @spec videos_for_crf_search_preview(integer(), keyword()) :: [map()]
  def videos_for_crf_search_preview(limit \\ 10, opts \\ []),
    do: cached_dashboard_queue_preview(:crf_searcher, limit, opts)

  @doc """
  Gets videos ready for encoding with complex alternation logic between services and libraries.
  Uses 9:1 Sonarr:Radarr ratio and alternates between libraries within each service.

  ## Options
  - `:timeout` - Query timeout in milliseconds (default: 15000)
  """
  @spec videos_ready_for_encoding(integer(), keyword()) :: [Vmaf.t()]
  def videos_ready_for_encoding(limit, opts \\ []) do
    Repo.all(
      from(vid in Video,
        join: v in Vmaf,
        on: vid.chosen_vmaf_id == v.id,
        where: vid.state == :crf_searched,
        order_by: [desc: vid.priority, desc: v.savings, desc: vid.updated_at],
        limit: ^limit,
        select: %{v | video: vid}
      ),
      opts
    )
  end

  @doc """
  Gets a lightweight preview of videos ready for encoding for dashboard display.
  """
  @spec videos_ready_for_encoding_preview(integer(), keyword()) :: [map()]
  def videos_ready_for_encoding_preview(limit, opts \\ []),
    do: cached_dashboard_queue_preview(:encoder, limit, opts)

  @doc """
  Returns all cached dashboard queue preview items.

  The dashboard uses this single cache-backed query so queue previews no longer
  hit the live `videos` table during refresh.
  """
  @spec dashboard_queue_preview_items(keyword()) :: [DashboardQueueCache.t()]
  def dashboard_queue_preview_items(opts \\ []) do
    Repo.all(
      from(q in DashboardQueueCache,
        where: q.queue_type in [:analyzer, :crf_searcher, :encoder],
        select: q
      ),
      opts
    )
  end

  defp queue_preview_items(queue_type, opts) do
    dashboard_queue_preview_items(opts)
    |> Enum.filter(&(&1.queue_type == queue_type))
    |> Enum.sort_by(&queue_preview_sort_key(queue_type, &1))
  end

  defp cached_dashboard_queue_preview(queue_type, limit, opts) do
    queue_preview_items(queue_type, opts)
    |> Enum.take(limit)
    |> Enum.map(&queue_preview_item/1)
  end

  defp queue_preview_sort_key(:analyzer, row) do
    {
      -normalize_int(row.priority),
      -normalize_int(row.size),
      -timestamp(row.inserted_at),
      -timestamp(row.updated_at)
    }
  end

  defp queue_preview_sort_key(:crf_searcher, row) do
    {
      -normalize_int(row.priority),
      -normalize_int(row.bitrate),
      -normalize_int(row.size),
      timestamp(row.updated_at)
    }
  end

  defp queue_preview_sort_key(:encoder, row) do
    {
      -normalize_int(row.priority),
      -normalize_int(row.savings),
      -timestamp(row.updated_at)
    }
  end

  defp normalize_int(nil), do: 0
  defp normalize_int(value) when is_integer(value), do: value

  defp timestamp(nil), do: 0
  defp timestamp(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp queue_preview_item(row), do: %{id: row.video_id, path: row.path}

  @doc """
  Counts total videos ready for encoding.
  """
  @spec encoding_queue_count(keyword()) :: integer()
  def encoding_queue_count(opts \\ []) do
    Repo.one(
      from(vid in Video,
        where: vid.state == :crf_searched and not is_nil(vid.chosen_vmaf_id),
        select: count(vid.id)
      ),
      opts
    )
  end
end
