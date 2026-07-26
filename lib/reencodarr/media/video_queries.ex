defmodule Reencodarr.Media.VideoQueries do
  @moduledoc """
  Centralizes complex video query logic to reduce complexity in the Media module.

  This module handles the intricate logic for alternating between services and libraries
  when selecting videos for encoding, CRF search, and analysis.
  """

  import Ecto.Query
  alias Reencodarr.{DbWriter, Media.DashboardQueueCache, Media.Video, Media.Vmaf, Repo}

  @doc """
  Gets videos ready for CRF search (state: analyzed).
  Excludes videos already in crf_searching state to avoid showing currently processing videos.

  ## Options
  - `:timeout` - Query timeout in milliseconds (default: 15000)
  """
  @spec videos_for_crf_search(integer(), keyword()) :: [Video.t()]
  def videos_for_crf_search(limit \\ 10, opts \\ []) do
    ids = crf_search_queue_candidate_ids(limit, opts)

    Video
    |> where([v], v.id in ^ids)
    |> Repo.all(opts)
    |> sort_by_ids(ids)
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
  Atomically claims the next video ready for CRF search.

  Returns `nil` when the queue is empty. The claim transitions the selected
  video from `:analyzed` to `:crf_searching` so only one worker can receive it.
  """
  @spec claim_next_video_for_crf_search(keyword()) :: Video.t() | nil
  def claim_next_video_for_crf_search(opts \\ []) do
    DbWriter.transaction(
      fn ->
        claim_next_video_for_crf_search_in_tx(opts)
      end,
      label: :video_queries_claim_next_video_for_crf_search
    )
    |> case do
      {:ok, {:claimed, video, old_snapshot}} ->
        Reencodarr.Media.broadcast_video_mutation(
          :update,
          old_snapshot,
          Reencodarr.Media.fetch_dashboard_video_snapshot_by_id(video.id)
        )

        video

      {:ok, :none} ->
        nil

      {:error, reason} ->
        raise "Failed to claim video for CRF search: #{inspect(reason)}"
    end
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
  def videos_needing_analysis_preview(limit \\ 10, opts \\ []) do
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
        select: %{id: v.id, path: v.path}
      ),
      opts
    )
  end

  @doc """
  Atomically claims videos for analysis by transitioning them from
  `:needs_analysis` to `:analyzing`. Returns the claimed video IDs.

  This prevents race conditions where the same video could be fetched
  by multiple producer demand cycles before the batch processor
  transitions them to `:analyzed`.
  """
  @spec claim_videos_for_analysis(integer(), keyword()) :: [Video.t()]
  def claim_videos_for_analysis(limit, opts \\ []) do
    DbWriter.transaction(
      fn ->
        candidate_ids =
          from(v in Video,
            where: v.state == :needs_analysis,
            order_by: [desc: v.priority, desc: v.size, desc: v.inserted_at],
            limit: ^limit,
            select: v.id
          )
          |> Repo.all(opts)

        case candidate_ids do
          [] ->
            {[], %{}}

          ids ->
            old_snapshots_by_id =
              ids
              |> Reencodarr.Media.fetch_dashboard_video_snapshots_by_ids()
              |> Map.new(&{&1.id, &1})

            {_count, claimed} =
              from(v in Video,
                where: v.id in ^ids and v.state == :needs_analysis,
                select: v
              )
              |> Repo.update_all([set: [state: :analyzing, updated_at: DateTime.utc_now()]], opts)

            {claimed, old_snapshots_by_id}
        end
      end,
      label: :video_queries_claim_videos_for_analysis
    )
    |> case do
      {:ok, {claimed, old_snapshots_by_id}} ->
        broadcast_analysis_claims(old_snapshots_by_id, claimed)
        claimed

      {:error, reason} ->
        raise "Failed to claim videos for analysis: #{inspect(reason)}"
    end
  end

  defp broadcast_analysis_claims(old_snapshots_by_id, claimed) do
    Enum.each(claimed, fn video ->
      Reencodarr.Media.broadcast_video_mutation(
        :update,
        Map.get(old_snapshots_by_id, video.id),
        Reencodarr.Media.fetch_dashboard_video_snapshot_by_id(video.id)
      )
    end)
  end

  defp claim_next_video_for_crf_search_in_tx(opts) do
    claim_next_video_for_crf_search_in_tx(crf_search_queue_candidate_ids(10, opts), opts)
  end

  defp claim_next_video_for_crf_search_in_tx([], _opts), do: :none

  defp claim_next_video_for_crf_search_in_tx([video_id | rest], opts) do
    old_snapshot = Reencodarr.Media.fetch_dashboard_video_snapshot_by_id(video_id)
    set_fields = crf_search_claim_fields(opts)

    {updated_count, updated_rows} =
      from(v in Video,
        where: v.id == ^video_id and v.state == :analyzed,
        select: v
      )
      |> Repo.update_all([set: set_fields], opts)

    case {updated_count, updated_rows} do
      {1, [video]} ->
        {:claimed, video, old_snapshot}

      _ ->
        claim_next_video_for_crf_search_in_tx(rest, opts)
    end
  end

  defp crf_search_claim_fields(opts) do
    fields = [state: :crf_searching, updated_at: DateTime.utc_now()]
    worker_id = Keyword.get(opts, :worker_id)
    attempt_id = Keyword.get(opts, :attempt_id)

    case {worker_id, attempt_id} do
      {nil, nil} ->
        fields

      {worker_id, attempt_id} when is_binary(worker_id) and is_binary(attempt_id) ->
        Keyword.merge(fields,
          crf_search_worker_id: worker_id,
          worker_attempt_id: attempt_id,
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running,
          worker_control_command_id: nil,
          worker_terminal_claimed_at: nil
        )

      _ ->
        raise ArgumentError, "worker_id and attempt_id must be supplied together"
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
  def videos_for_crf_search_preview(limit \\ 10, opts \\ []) do
    crf_search_queue_preview_rows(limit, opts)
  end

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
  Atomically claims the next video ready for encoding.

  The worker and attempt are persisted in the same conditional update that
  transitions the video to `:encoding`.
  """
  @spec claim_next_video_for_encoding(String.t(), String.t(), keyword()) :: Vmaf.t() | nil
  def claim_next_video_for_encoding(worker_id, attempt_id, opts \\ [])
      when is_binary(worker_id) and is_binary(attempt_id) do
    DbWriter.transaction(
      fn ->
        claim_next_video_for_encoding_in_tx(
          encoding_queue_candidate_ids(10, opts),
          worker_id,
          attempt_id,
          opts
        )
      end,
      label: :video_queries_claim_next_video_for_encoding
    )
    |> case do
      {:ok, {:claimed, vmaf, old_snapshot}} ->
        Reencodarr.Media.broadcast_video_mutation(
          :update,
          old_snapshot,
          Reencodarr.Media.fetch_dashboard_video_snapshot_by_id(vmaf.video.id)
        )

        vmaf

      {:ok, :none} ->
        nil

      {:error, reason} ->
        raise "Failed to claim video for encoding: #{inspect(reason)}"
    end
  end

  @doc """
  Gets a lightweight preview of videos ready for encoding for dashboard display.
  """
  @spec videos_ready_for_encoding_preview(integer(), keyword()) :: [map()]
  def videos_ready_for_encoding_preview(limit, opts \\ []) do
    Repo.all(
      from(c in DashboardQueueCache,
        where: c.queue_type == :encoder,
        order_by: [desc: c.priority, desc: c.savings, desc: c.updated_at],
        limit: ^limit,
        select: %{id: c.video_id, path: c.path}
      ),
      opts
    )
  end

  defp encoding_queue_candidate_ids(limit, opts) do
    Repo.all(
      from(vid in Video,
        join: v in Vmaf,
        on: vid.chosen_vmaf_id == v.id,
        where: vid.state == :crf_searched,
        order_by: [desc: vid.priority, desc: v.savings, desc: vid.updated_at],
        limit: ^limit,
        select: vid.id
      ),
      opts
    )
  end

  defp claim_next_video_for_encoding_in_tx([], _worker_id, _attempt_id, _opts), do: :none

  defp claim_next_video_for_encoding_in_tx(
         [video_id | rest],
         worker_id,
         attempt_id,
         opts
       ) do
    old_snapshot = Reencodarr.Media.fetch_dashboard_video_snapshot_by_id(video_id)
    video = Repo.get!(Video, video_id)
    original_size = video.original_size || video.size

    {updated_count, updated_rows} =
      from(v in Video,
        where: v.id == ^video_id and v.state == :crf_searched,
        select: v
      )
      |> Repo.update_all(
        [
          set: [
            state: :encoding,
            encode_worker_id: worker_id,
            worker_attempt_id: attempt_id,
            worker_control_desired_state: :running,
            worker_control_acknowledged_state: :running,
            worker_control_command_id: nil,
            worker_terminal_claimed_at: nil,
            original_size: original_size,
            updated_at: DateTime.utc_now()
          ]
        ],
        opts
      )

    case {updated_count, updated_rows} do
      {1, [claimed_video]} ->
        vmaf = Repo.get!(Vmaf, claimed_video.chosen_vmaf_id)
        {:claimed, %{vmaf | video: claimed_video}, old_snapshot}

      _ ->
        claim_next_video_for_encoding_in_tx(rest, worker_id, attempt_id, opts)
    end
  end

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

  defp crf_search_queue_candidate_ids(limit, opts) do
    crf_search_queue_rows("id", limit, opts)
    |> Enum.map(fn [id] -> id end)
  end

  defp crf_search_queue_preview_rows(limit, opts) do
    crf_search_queue_rows("id, path", limit, opts)
    |> Enum.map(fn [id, path] -> %{id: id, path: path} end)
  end

  defp crf_search_queue_rows(select, limit, opts) do
    sql = """
    SELECT #{select}
    FROM videos INDEXED BY videos_crf_search_queue_index
    WHERE state = 'analyzed'
    ORDER BY priority DESC, bitrate DESC, size DESC, updated_at ASC
    LIMIT ?
    """

    %{rows: rows} = Repo.query!(sql, [limit], opts)
    rows
  end

  defp sort_by_ids(videos, ids) do
    videos_by_id = Map.new(videos, &{&1.id, &1})
    Enum.map(ids, &Map.fetch!(videos_by_id, &1))
  end
end
