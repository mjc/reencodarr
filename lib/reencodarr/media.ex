defmodule Reencodarr.Media do
  import Ecto.Query

  import __MODULE__.SharedQueries,
    only: [videos_with_no_chosen_vmafs_query: 0],
    warn: false

  alias Reencodarr.AbAv1.{CrfSearch, Encode}
  alias Reencodarr.Analyzer.Broadway, as: AnalyzerBroadway
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.DbWriter

  alias Reencodarr.Media.{
    BadFileIssue,
    Library,
    SharedQueries,
    Video,
    VideoFailure,
    VideoQueries,
    VideoStateMachine,
    VideoUpsert,
    Vmaf
  }

  alias Reencodarr.Repo
  alias Reencodarr.Rules
  require Logger

  @moduledoc "Handles media-related operations and database interactions."
  @queueable_states [:needs_analysis, :analyzed, :crf_searched]
  @missing_file_scan_batch_size 50
  @missing_file_delete_batch_size 25
  @missing_file_check_concurrency 2
  @missing_file_check_timeout_ms 2_000
  @missing_file_batch_pause_ms 25

  defp write(fun, opts) when is_function(fun, 0), do: DbWriter.run(fun, opts)
  defp write_transaction(fun, opts) when is_function(fun, 0), do: DbWriter.transaction(fun, opts)

  # --- Video-related functions ---
  def list_videos, do: Repo.all(from v in Video, order_by: [desc: v.updated_at])
  def get_video!(id), do: Repo.get!(Video, id)

  @doc """
  Gets a video by its file path.

  Returns {:ok, video} if found, {:error, :not_found} otherwise.
  """
  @spec get_video_by_path(String.t()) :: {:ok, Video.t()} | {:error, :not_found}
  def get_video_by_path(path) do
    case Repo.one(from v in Video, where: v.path == ^path) do
      nil -> {:error, :not_found}
      video -> {:ok, video}
    end
  end

  def video_exists?(path), do: Repo.exists?(from v in Video, where: v.path == ^path)

  def find_videos_by_path_wildcard(pattern),
    do: Repo.all(from v in Video, where: like(v.path, ^pattern))

  def get_videos_for_crf_search(limit \\ 10) do
    VideoQueries.videos_for_crf_search(limit)
  end

  def count_videos_for_crf_search do
    VideoQueries.count_videos_for_crf_search()
  end

  def get_videos_needing_analysis(limit \\ 10) do
    VideoQueries.videos_needing_analysis(limit)
  end

  def claim_videos_for_analysis(limit) do
    VideoQueries.claim_videos_for_analysis(limit)
  end

  def count_videos_needing_analysis do
    VideoQueries.count_videos_needing_analysis()
  end

  # Query for videos ready for encoding (chosen VMAFs with valid videos)
  defp query_videos_ready_for_encoding(limit) do
    VideoQueries.videos_ready_for_encoding(limit)
  end

  def list_videos_by_estimated_percent(limit \\ 10) do
    query_videos_ready_for_encoding(limit)
  end

  def get_next_for_encoding(limit \\ 1) do
    query_videos_ready_for_encoding(limit)
  end

  def encoding_queue_count do
    VideoQueries.encoding_queue_count()
  end

  def upsert_video(attrs) do
    path = Map.get(attrs, :path) || Map.get(attrs, "path")
    old_video = if is_binary(path), do: fetch_dashboard_video_snapshot_by_path(path)

    write(
      fn ->
        %Video{}
        |> Video.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace_all_except, [:id, :inserted_at, :updated_at]},
          conflict_target: :path
        )
        |> tap(&broadcast_upserted_video(&1, old_video))
      end,
      label: :media_upsert_video
    )
  end

  def batch_upsert_videos(video_attrs_list) do
    VideoUpsert.batch_upsert(video_attrs_list)
  end

  def update_video(%Video{} = video, attrs) do
    old_video = fetch_dashboard_video_snapshot_by_id(video.id) || dashboard_video_snapshot(video)

    write(
      fn ->
        case video |> Video.changeset(attrs) |> Repo.update() do
          {:ok, %Video{} = updated_video} ->
            broadcast_video_mutation(
              :update,
              old_video,
              fetch_dashboard_video_snapshot_by_id(updated_video.id)
            )

            {:ok, updated_video}

          other ->
            other
        end
      end,
      label: :media_update_video
    )
  end

  @doc """
  Moves queueable videos to the top of their queue in the provided order.

  Higher priority values are processed first by the analyzer, CRF searcher,
  and encoder queries. Non-queueable videos are ignored.
  """
  @spec prioritize_videos([integer()]) :: {:ok, non_neg_integer()}
  def prioritize_videos(ids) when is_list(ids) do
    ordered_ids = ids |> Enum.uniq() |> Enum.reject(&is_nil/1)

    write_transaction(
      fn ->
        queueable_by_id =
          from(v in Video,
            where: v.id in ^ordered_ids and v.state in ^@queueable_states,
            select: {v.id, v}
          )
          |> Repo.all()
          |> Map.new()

        prioritized_ids =
          ordered_ids
          |> Enum.filter(&Map.has_key?(queueable_by_id, &1))

        max_priority = highest_queue_priority()
        total = length(prioritized_ids)

        assign_priorities(prioritized_ids, queueable_by_id, max_priority, total)

        total
      end,
      label: :media_prioritize_videos
    )
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec prioritize_video(integer() | Video.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prioritize_video(%Video{id: id}), do: prioritize_videos([id])
  def prioritize_video(id) when is_integer(id), do: prioritize_videos([id])

  def delete_video(%Video{} = video) do
    old_video = fetch_dashboard_video_snapshot_by_id(video.id) || dashboard_video_snapshot(video)

    write(
      fn ->
        case Repo.delete(video) do
          {:ok, deleted_video} ->
            broadcast_video_mutation(:delete, old_video, nil)
            {:ok, deleted_video}

          other ->
            other
        end
      end,
      label: :media_delete_video
    )
  end

  def delete_video_with_vmafs(%Video{} = video) do
    delete_videos_by_ids([video.id])
  end

  def change_video(%Video{} = video, attrs \\ %{}) do
    Video.changeset(video, attrs)
  end

  def mark_as_crf_searching(%Video{} = video), do: VideoStateMachine.mark_as_crf_searching(video)

  def mark_as_encoding(%Video{} = video), do: VideoStateMachine.mark_as_encoding(video)

  def mark_as_reencoded(%Video{} = video), do: VideoStateMachine.mark_as_reencoded(video)

  def mark_as_failed(%Video{} = video), do: VideoStateMachine.mark_as_failed(video)

  def mark_as_analyzed(%Video{} = video), do: VideoStateMachine.mark_as_analyzed(video)

  def mark_as_crf_searched(%Video{} = video), do: VideoStateMachine.mark_as_crf_searched(video)

  def mark_as_needs_analysis(%Video{} = video),
    do: VideoStateMachine.mark_as_needs_analysis(video)

  def mark_as_encoded(%Video{} = video), do: VideoStateMachine.mark_as_encoded(video)

  # --- Bad File Issue Functions ---

  @resolved_bad_file_issue_statuses [:replaced_clean, :dismissed]

  @spec list_bad_file_issues(keyword()) :: [BadFileIssue.t()]
  def list_bad_file_issues(opts \\ []) do
    video_preload_query =
      from v in Video,
        select: struct(v, [:id, :path, :service_type, :service_id])

    BadFileIssue
    |> bad_file_issue_filters_query(opts)
    |> order_by([i], desc: i.updated_at, desc: i.id)
    |> maybe_limit_bad_file_issues(Keyword.get(opts, :limit))
    |> maybe_offset_bad_file_issues(Keyword.get(opts, :offset))
    |> Repo.all()
    |> Repo.preload(video: video_preload_query)
  end

  @spec count_bad_file_issues(keyword()) :: non_neg_integer()
  def count_bad_file_issues(opts \\ []) do
    BadFileIssue
    |> bad_file_issue_filters_query(opts)
    |> select([i], count(i.id))
    |> Repo.one()
  end

  @spec bad_file_issue_summary() :: %{
          open: non_neg_integer(),
          queued: non_neg_integer(),
          processing: non_neg_integer(),
          waiting_for_replacement: non_neg_integer(),
          failed: non_neg_integer(),
          resolved: non_neg_integer()
        }
  def bad_file_issue_summary do
    Repo.all(
      from i in BadFileIssue,
        group_by: i.status,
        select: {i.status, count(i.id)}
    )
    |> Enum.reduce(
      %{open: 0, queued: 0, processing: 0, waiting_for_replacement: 0, failed: 0, resolved: 0},
      fn
        {:open, count}, acc -> %{acc | open: count}
        {:queued, count}, acc -> %{acc | queued: count}
        {:processing, count}, acc -> %{acc | processing: count}
        {:waiting_for_replacement, count}, acc -> %{acc | waiting_for_replacement: count}
        {:failed, count}, acc -> %{acc | failed: count}
        {_resolved_status, count}, acc -> %{acc | resolved: acc.resolved + count}
      end
    )
  end

  @spec unresolved_bad_file_issues_by_video_ids([integer()]) :: %{integer() => BadFileIssue.t()}
  def unresolved_bad_file_issues_by_video_ids(video_ids) when is_list(video_ids) do
    case Enum.uniq(Enum.filter(video_ids, &is_integer/1)) do
      [] ->
        %{}

      filtered_ids ->
        Repo.all(
          from i in BadFileIssue,
            where:
              i.video_id in ^filtered_ids and i.status not in ^@resolved_bad_file_issue_statuses,
            order_by: [desc: i.updated_at, desc: i.id]
        )
        |> Enum.reduce(%{}, fn issue, acc ->
          Map.put_new(acc, issue.video_id, issue)
        end)
    end
  end

  @spec get_bad_file_issue!(integer()) :: BadFileIssue.t()
  def get_bad_file_issue!(id), do: Repo.get!(BadFileIssue, id) |> Repo.preload(:video)

  @spec fetch_bad_file_issue(integer()) :: {:ok, BadFileIssue.t()} | :not_found
  def fetch_bad_file_issue(id) when is_integer(id) do
    case Repo.get(BadFileIssue, id) do
      %BadFileIssue{} = issue -> {:ok, Repo.preload(issue, :video)}
      nil -> :not_found
    end
  end

  @spec create_bad_file_issue(Video.t(), map()) ::
          {:ok, BadFileIssue.t()} | {:error, Ecto.Changeset.t()}
  def create_bad_file_issue(%Video{} = video, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put(:video_id, video.id)
      |> normalize_bad_file_issue_attrs()

    write(
      fn ->
        case find_existing_unresolved_bad_file_issue(video.id, attrs) do
          nil ->
            %BadFileIssue{}
            |> BadFileIssue.changeset(attrs)
            |> Repo.insert()

          existing ->
            existing
            |> BadFileIssue.changeset(attrs)
            |> Repo.update()
        end
      end,
      label: :media_create_bad_file_issue
    )
  end

  @spec enqueue_bad_file_issue(BadFileIssue.t()) ::
          {:ok, BadFileIssue.t()} | {:error, Ecto.Changeset.t()}
  def enqueue_bad_file_issue(%BadFileIssue{} = issue),
    do: update_bad_file_issue_status(issue, :queued)

  @spec retry_bad_file_issue(BadFileIssue.t()) ::
          {:ok, BadFileIssue.t()} | {:error, Ecto.Changeset.t()}
  def retry_bad_file_issue(%BadFileIssue{} = issue),
    do: update_bad_file_issue_status(issue, :queued)

  @spec dismiss_bad_file_issue(BadFileIssue.t()) ::
          {:ok, BadFileIssue.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_bad_file_issue(%BadFileIssue{} = issue) do
    update_bad_file_issue_status(issue, :dismissed)
  end

  @spec update_bad_file_issue_status(BadFileIssue.t(), atom()) ::
          {:ok, BadFileIssue.t()} | {:error, Ecto.Changeset.t()}
  def update_bad_file_issue_status(%BadFileIssue{} = issue, status) when is_atom(status) do
    attrs =
      %{status: status}
      |> maybe_put_bad_file_issue_timestamps(status)

    write(
      fn ->
        issue
        |> BadFileIssue.changeset(attrs)
        |> Repo.update()
      end,
      label: :media_update_bad_file_issue_status
    )
  end

  @spec next_queued_bad_file_issue() :: BadFileIssue.t() | nil
  def next_queued_bad_file_issue do
    next_queued_bad_file_issue(:all)
  end

  @spec next_queued_bad_file_issue(atom()) :: BadFileIssue.t() | nil
  def next_queued_bad_file_issue(:all) do
    Repo.one(
      from i in BadFileIssue,
        where: i.status == :queued,
        preload: [:video],
        order_by: [asc: i.inserted_at, asc: i.id],
        limit: 1
    )
  end

  def next_queued_bad_file_issue(service_type) when service_type in [:sonarr, :radarr] do
    Repo.one(
      from i in BadFileIssue,
        join: v in assoc(i, :video),
        where: i.status == :queued and v.service_type == ^service_type,
        preload: [video: v],
        order_by: [asc: i.inserted_at, asc: i.id],
        limit: 1
    )
  end

  def next_queued_bad_file_issue(_service_type), do: nil

  @spec enqueue_bad_file_issues([BadFileIssue.t()]) :: {:ok, non_neg_integer()}
  def enqueue_bad_file_issues(issues) when is_list(issues) do
    count =
      issues
      |> Enum.reduce(0, fn
        %BadFileIssue{} = issue, acc ->
          case enqueue_bad_file_issue(issue) do
            {:ok, _queued_issue} -> acc + 1
            {:error, _changeset} -> acc
          end

        _other, acc ->
          acc
      end)

    {:ok, count}
  end

  @spec queue_bad_file_issue_series(BadFileIssue.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def queue_bad_file_issue_series(%BadFileIssue{} = issue) do
    issue = Repo.preload(issue, :video)

    case series_group_key(issue.video) do
      nil ->
        {:error, :not_series_scoped}

      group_key ->
        issues =
          list_bad_file_issues()
          |> Enum.filter(fn candidate ->
            unresolved_bad_file_issue?(candidate) and
              series_group_key(candidate.video) == group_key
          end)

        Enum.each(issues, &enqueue_bad_file_issue/1)
        {:ok, length(issues)}
    end
  end

  @spec resolve_waiting_bad_file_issues_for_video(Video.t()) :: {:ok, non_neg_integer()}
  def resolve_waiting_bad_file_issues_for_video(%Video{} = video) do
    issues =
      Repo.all(
        from i in BadFileIssue,
          where: i.video_id == ^video.id and i.status == :waiting_for_replacement,
          order_by: [asc: i.id]
      )

    Enum.each(issues, fn issue ->
      {:ok, _updated_issue} = update_bad_file_issue_status(issue, :replaced_clean)
    end)

    {:ok, length(issues)}
  end

  @spec reconcile_replacement_video(Video.t(), atom()) :: {:ok, Video.t()}
  def reconcile_replacement_video(%Video{} = video, service_type)
      when service_type in [:sonarr, :radarr] do
    {:ok, _resolved_count} = resolve_waiting_bad_file_issues_for_video(video)

    Events.broadcast_event(:sync_completed, %{
      service_type: service_type,
      source: :webhook,
      path: video.path
    })

    {:ok, video}
  end

  defp normalize_bad_file_issue_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_binary(key) -> Map.put(acc, String.to_existing_atom(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp find_existing_unresolved_bad_file_issue(video_id, attrs) do
    issue_kind = Map.get(attrs, :issue_kind)
    classification = Map.get(attrs, :classification)

    Repo.one(
      from i in BadFileIssue,
        where:
          i.video_id == ^video_id and
            i.issue_kind == ^issue_kind and
            i.classification == ^classification and
            i.status not in ^@resolved_bad_file_issue_statuses,
        order_by: [desc: i.updated_at, desc: i.id],
        limit: 1
    )
  end

  defp maybe_put_bad_file_issue_timestamps(attrs, status) do
    attrs
    |> maybe_put_resolved_at(status)
    |> maybe_put_last_attempted_at(status)
  end

  defp maybe_put_resolved_at(attrs, status) when status in @resolved_bad_file_issue_statuses do
    Map.put(attrs, :resolved_at, DateTime.utc_now())
  end

  defp maybe_put_resolved_at(attrs, _status), do: attrs

  defp maybe_put_last_attempted_at(attrs, status)
       when status in [:queued, :processing, :waiting_for_replacement, :failed] do
    Map.put(attrs, :last_attempted_at, DateTime.utc_now())
  end

  defp maybe_put_last_attempted_at(attrs, _status), do: attrs

  defp bad_file_issue_filters_query(queryable, opts) do
    queryable
    |> maybe_filter_bad_file_issue_statuses(Keyword.get(opts, :statuses, :all))
    |> maybe_filter_bad_file_issue_service(Keyword.get(opts, :service, "all"))
    |> maybe_filter_bad_file_issue_kind(Keyword.get(opts, :kind, "all"))
    |> maybe_filter_bad_file_issue_search(Keyword.get(opts, :search, ""))
  end

  defp maybe_filter_bad_file_issue_statuses(query, :all), do: query

  defp maybe_filter_bad_file_issue_statuses(query, statuses) when is_list(statuses) do
    from i in query, where: i.status in ^statuses
  end

  defp maybe_filter_bad_file_issue_service(query, "all"), do: query

  defp maybe_filter_bad_file_issue_service(query, service) when service in ["sonarr", "radarr"] do
    service_type = String.to_existing_atom(service)
    query = ensure_bad_file_issue_video_join(query)
    from [i, video: v] in query, where: v.service_type == ^service_type
  end

  defp maybe_filter_bad_file_issue_service(query, _service), do: query

  defp maybe_filter_bad_file_issue_kind(query, "all"), do: query

  defp maybe_filter_bad_file_issue_kind(query, kind) when kind in ["audio", "manual"] do
    issue_kind = String.to_existing_atom(kind)
    from i in query, where: i.issue_kind == ^issue_kind
  end

  defp maybe_filter_bad_file_issue_kind(query, _kind), do: query

  defp maybe_filter_bad_file_issue_search(query, ""), do: query

  defp maybe_filter_bad_file_issue_search(query, search) when is_binary(search) do
    pattern = "%" <> String.downcase(search) <> "%"
    query = ensure_bad_file_issue_video_join(query)

    from [i, video: v] in query,
      where:
        fragment("lower(?) like ?", v.path, ^pattern) or
          fragment("lower(coalesce(?, '')) like ?", i.manual_reason, ^pattern) or
          fragment("lower(coalesce(?, '')) like ?", i.manual_note, ^pattern) or
          fragment("lower(?) like ?", i.classification, ^pattern) or
          fragment("lower(?) like ?", i.issue_kind, ^pattern)
  end

  defp maybe_filter_bad_file_issue_search(query, _search), do: query

  defp maybe_limit_bad_file_issues(query, limit) when is_integer(limit) and limit > 0 do
    from i in query, limit: ^limit
  end

  defp maybe_limit_bad_file_issues(query, _limit), do: query

  defp maybe_offset_bad_file_issues(query, offset) when is_integer(offset) and offset >= 0 do
    from i in query, offset: ^offset
  end

  defp maybe_offset_bad_file_issues(query, _offset), do: query

  defp ensure_bad_file_issue_video_join(%Ecto.Query{aliases: aliases} = query) do
    case Map.has_key?(aliases, :video) do
      true -> query
      false -> join(query, :inner, [i], v in assoc(i, :video), as: :video)
    end
  end

  defp unresolved_bad_file_issue?(issue) do
    issue.status not in [:replaced_clean, :dismissed]
  end

  defp series_group_key(%Video{service_type: :sonarr, path: path}) when is_binary(path) do
    dir = Path.dirname(path)

    if Regex.match?(~r/^[Ss](?:eason\s*)?0*\d+$/i, Path.basename(dir)) do
      Path.dirname(dir)
    else
      dir
    end
  end

  defp series_group_key(_video), do: nil

  @doc """
  Bulk-marks all :analyzed videos that are already AV1 (by codec or filename) as :encoded.

  Returns `{count, nil}` like `Repo.update_all/2`.
  """
  def mark_analyzed_av1_videos_as_encoded do
    write(
      fn ->
        Repo.update_all(
          from(v in Video,
            where: v.state == :analyzed,
            where:
              fragment("? LIKE '%\"V_AV1\"%'", v.video_codecs) or
                fragment("? LIKE '%\"AV1\"%'", v.video_codecs) or
                fragment("LOWER(?) LIKE '%av1%'", v.path)
          ),
          set: [state: :encoded]
        )
      end,
      label: :media_mark_analyzed_av1
    )
  end

  # --- Video Failure Tracking Functions ---

  @doc """
  Records a detailed failure for a video and marks it as failed.

  ## Examples

      iex> record_video_failure(video, "encoding", "process_failure",
      ...>   code: "1", message: "ab-av1 encoding failed")
      {:ok, %VideoFailure{}}
  """
  def record_video_failure(video, stage, category, opts \\ []) do
    with {:ok, failure} <- VideoFailure.record_failure(video, stage, category, opts),
         {:ok, _video} <- mark_as_failed(video) do
      Logger.warning(
        "Recorded #{stage}/#{category} failure for video #{video.id}: #{opts[:message] || "No message"}"
      )

      {:ok, failure}
    else
      {:error, %Ecto.Changeset{errors: [video_id: {"does not exist", _}]}} ->
        # Video was deleted during test cleanup - this is expected in test environment
        Logger.debug("Video #{video.id} no longer exists, skipping failure recording")
        {:ok, video}

      error ->
        Logger.error("Failed to record video failure: #{inspect(error)}")
        error
    end
  end

  @doc """
  Gets unresolved failures for a video.
  """
  def get_video_failures(video_id), do: VideoFailure.get_unresolved_failures_for_video(video_id)

  @doc """
  Resolves failures for a video (typically when re-processing succeeds).

  ## Options

    * `:stage` - when given, only resolves failures for that stage
      (e.g. `:crf_search`). Otherwise resolves all failures.
  """
  @spec resolve_video_failures(integer(), keyword()) :: {integer(), nil}
  def resolve_video_failures(video_id, opts \\ []) do
    now = DateTime.utc_now()

    write(
      fn ->
        from(f in VideoFailure,
          where: f.video_id == ^video_id and f.resolved == false,
          update: [set: [resolved: true, resolved_at: ^now]]
        )
        |> maybe_filter_failure_stage(opts[:stage])
        |> Repo.update_all([])
      end,
      label: :media_resolve_video_failures
    )
  end

  defp maybe_filter_failure_stage(query, nil), do: query

  defp maybe_filter_failure_stage(query, stage),
    do: from(f in query, where: f.failure_stage == ^stage)

  @doc """
  Resolves all unresolved CRF search failures for a video.

  Called when a CRF search retry begins — previous attempt failures are no
  longer relevant once a new attempt is underway; only the latest matters.
  """
  @spec resolve_crf_search_failures(integer()) :: {integer(), nil}
  def resolve_crf_search_failures(video_id) do
    resolve_video_failures(video_id, stage: :crf_search)
  end

  @doc """
  Gets failure statistics for monitoring and investigation.
  """
  def get_failure_statistics(opts \\ []), do: VideoFailure.get_failure_statistics(opts)

  @doc """
  Gets common failure patterns for investigation.
  """
  def get_common_failure_patterns(limit \\ 10),
    do: VideoFailure.get_common_failure_patterns(limit)

  @doc """
  Resets videos stuck in `:analyzing` back to `:needs_analysis`.

  Called on startup to reclaim videos that were being analyzed when the app crashed.
  """
  @spec reset_orphaned_analyzing() :: :ok
  def reset_orphaned_analyzing do
    from(v in Video, where: v.state == :analyzing)
    |> reset_videos("orphaned analyzing videos → needs_analysis", :needs_analysis)
  end

  @doc """
  Resets videos stuck in `:crf_searching` back to `:analyzed`.

  Called by the CRF Searcher Broadway pipeline on startup to reclaim orphaned work.
  Excludes videos currently being processed by the CRF search GenServer.

  ## Examples
      iex> Media.reset_orphaned_crf_searching()
      :ok
  """
  @spec reset_orphaned_crf_searching() :: :ok
  def reset_orphaned_crf_searching do
    exclude_id = CrfSearch.current_video_id()

    from(v in Video, where: v.state == :crf_searching)
    |> maybe_exclude_video(exclude_id)
    |> reset_videos("orphaned crf_searching videos → analyzed")
  end

  @doc """
  Resets videos stuck in `:encoding` back to `:crf_searched`.

  Called by the Encoder Broadway pipeline on startup to reclaim orphaned work.
  Excludes videos currently being processed by the Encode GenServer.

  ## Examples
      iex> Media.reset_orphaned_encoding()
      :ok
  """
  @spec reset_orphaned_encoding() :: :ok
  def reset_orphaned_encoding do
    exclude_id = Encode.current_video_id()

    {with_vmaf, without_vmaf} =
      write(
        fn ->
          # Videos that have a chosen VMAF can safely go back to crf_searched for re-encoding.
          {with_vmaf, _} =
            from(v in Video, where: v.state == :encoding, where: not is_nil(v.chosen_vmaf_id))
            |> maybe_exclude_video(exclude_id)
            |> Repo.update_all(set: [state: :crf_searched, updated_at: DateTime.utc_now()])

          # Videos without a chosen VMAF must go back to analyzed — they were never
          # encodable in the first place and need CRF search to run first.
          {without_vmaf, _} =
            from(v in Video, where: v.state == :encoding, where: is_nil(v.chosen_vmaf_id))
            |> maybe_exclude_video(exclude_id)
            |> Repo.update_all(set: [state: :analyzed, updated_at: DateTime.utc_now()])

          {with_vmaf, without_vmaf}
        end,
        label: :media_reset_orphaned_encoding
      )

    total = with_vmaf + without_vmaf

    if total > 0 do
      Logger.info(
        "Reset #{total} orphaned encoding videos (#{with_vmaf} → crf_searched, #{without_vmaf} → analyzed)"
      )
    end

    :ok
  end

  @doc """
  Resets videos stuck in `:crf_searched` with no chosen VMAF back to `:analyzed`.

  A `crf_searched` video with no chosen VMAF will never be picked up by the encoder,
  so it would be stuck forever. This function recovers them so CRF search can run again.

  Called by the Encoder Broadway pipeline on startup.

  ## Examples
      iex> Media.reset_crf_searched_without_vmaf()
      :ok
  """
  @spec reset_crf_searched_without_vmaf() :: :ok
  def reset_crf_searched_without_vmaf do
    from(v in Video, where: v.state == :crf_searched, where: is_nil(v.chosen_vmaf_id))
    |> reset_videos("crf_searched videos without chosen VMAF → analyzed")
  end

  defp reset_videos(query, log_message, target_state \\ :analyzed) do
    {count, _} =
      write(
        fn ->
          Repo.update_all(query, set: [state: target_state, updated_at: DateTime.utc_now()])
        end,
        label: :media_reset_videos
      )

    if count > 0, do: Logger.info("Reset #{count} #{log_message}")
    :ok
  end

  defp maybe_exclude_video(query, nil), do: query
  defp maybe_exclude_video(query, video_id), do: from(v in query, where: v.id != ^video_id)

  @doc """
  Counts videos that would generate invalid audio encoding arguments (b:a=0k, ac=0).

  Tests each video by calling Rules.build_args/2 and checking if it produces invalid
  audio encoding arguments like "--enc b:a=0k" or "--enc ac=0". Useful for monitoring
  and deciding whether to run reset_videos_with_invalid_audio_args/0.

  ## Examples
      iex> Media.count_videos_with_invalid_audio_args()
      %{videos_tested: 1250, videos_with_invalid_args: 42}
  """
  @spec count_videos_with_invalid_audio_args() :: %{
          videos_tested: integer(),
          videos_with_invalid_args: integer()
        }
  def count_videos_with_invalid_audio_args do
    # Get all videos that haven't been processed yet
    videos_to_test =
      from(v in Video,
        where: v.state not in [:encoded, :failed],
        select: v
      )
      |> Repo.all()

    videos_tested_count = length(videos_to_test)

    # Test each video to see if it produces invalid audio args
    videos_with_invalid_args_count =
      videos_to_test
      |> Enum.count(&produces_invalid_audio_args?/1)

    %{
      videos_tested: videos_tested_count,
      videos_with_invalid_args: videos_with_invalid_args_count
    }
  end

  @doc """
  One-liner to reset videos that would generate invalid audio encoding arguments (b:a=0k, ac=0).

  Tests each video by calling Rules.build_args/2 and checking if it produces invalid
  audio encoding arguments like "--enc b:a=0k" or "--enc ac=0". Resets analysis
  fields and deletes VMAFs for videos that would generate these invalid arguments.

  ## Examples
      iex> Media.reset_videos_with_invalid_audio_args()
      %{videos_tested: 1250, videos_reset: 42, vmafs_deleted: 156}
  """
  @spec reset_videos_with_invalid_audio_args() :: %{
          videos_tested: integer(),
          videos_reset: integer(),
          vmafs_deleted: integer()
        }
  def reset_videos_with_invalid_audio_args do
    # Get all videos that haven't been processed yet
    videos_to_test =
      from(v in Video,
        where: v.state not in [:encoded, :failed],
        select: v
      )
      |> Repo.all()

    videos_tested_count = length(videos_to_test)

    # Test each video to see if it produces invalid audio args
    problematic_video_ids =
      videos_to_test
      |> Enum.filter(&produces_invalid_audio_args?/1)
      |> Enum.map(& &1.id)

    reset_problematic_videos(problematic_video_ids, videos_tested_count)
  end

  # Helper function to reset problematic videos
  defp reset_problematic_videos([], videos_tested_count) do
    %{videos_tested: videos_tested_count, videos_reset: 0, vmafs_deleted: 0}
  end

  defp reset_problematic_videos(problematic_video_ids, videos_tested_count) do
    videos_reset_count = length(problematic_video_ids)

    write_transaction(
      fn ->
        # Delete VMAFs for these videos (they were generated with bad audio data)
        {vmafs_deleted_count, _} =
          from(v in Vmaf, where: v.video_id in ^problematic_video_ids)
          |> Repo.delete_all()

        # Reset analysis fields to force re-analysis
        from(v in Video, where: v.id in ^problematic_video_ids)
        |> Repo.update_all(
          set: [
            bitrate: nil,
            video_codecs: nil,
            audio_codecs: nil,
            max_audio_channels: nil,
            atmos: nil,
            hdr: nil,
            width: nil,
            height: nil,
            frame_rate: nil,
            duration: nil,
            updated_at: DateTime.utc_now()
          ]
        )

        %{
          videos_tested: videos_tested_count,
          videos_reset: videos_reset_count,
          vmafs_deleted: vmafs_deleted_count
        }
      end,
      label: :media_reset_problematic_videos
    )
    |> case do
      {:ok, result} ->
        result

      {:error, _reason} ->
        %{videos_tested: videos_tested_count, videos_reset: 0, vmafs_deleted: 0}
    end
  end

  # Helper function to test if a video would produce invalid audio encoding arguments
  defp produces_invalid_audio_args?(video) do
    # Generate encoding arguments using the Rules module
    args = Reencodarr.Rules.build_args(video, :encode)

    # Look for invalid audio encoding arguments
    opus_args =
      args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn
        [flag, value] when flag == "--enc" ->
          String.contains?(value, "b:a=") or String.contains?(value, "ac=")

        _ ->
          false
      end)

    # Check if any of the audio args are invalid (0 bitrate or 0 channels)
    Enum.any?(opus_args, fn
      ["--enc", value] ->
        String.contains?(value, "b:a=0k") or String.contains?(value, "ac=0")

      _ ->
        false
    end)
  end

  @doc """
  One-liner to reset videos with invalid audio metadata that would cause 0 bitrate/channels.

  Finds videos where max_audio_channels is nil/0 OR audio_codecs is nil/empty,
  resets their analysis fields, and deletes their VMAFs since they're based on bad data.

  ## Examples
      iex> Media.reset_videos_with_invalid_audio_metadata()
      %{videos_reset: 42, vmafs_deleted: 156}
  """
  @spec reset_videos_with_invalid_audio_metadata() :: %{
          videos_reset: integer(),
          vmafs_deleted: integer()
        }
  def reset_videos_with_invalid_audio_metadata do
    write_transaction(
      fn ->
        # Find videos with problematic audio metadata that would cause Rules.audio/1 to return []
        # This happens when max_audio_channels is nil/0 OR audio_codecs is nil/empty
        # SQLite: audio_codecs is stored as JSON, check if empty with json_array_length
        problematic_video_ids =
          from(v in Video,
            where:
              v.state not in [:encoded, :failed] and
                v.atmos != true and
                (is_nil(v.max_audio_channels) or v.max_audio_channels == 0 or
                   is_nil(v.audio_codecs) or
                   fragment("json_array_length(?) = 0", v.audio_codecs)),
            select: v.id
          )
          |> Repo.all()

        videos_reset_count = length(problematic_video_ids)

        # Delete VMAFs for these videos (they were generated with bad audio data)
        {vmafs_deleted_count, _} =
          from(v in Vmaf, where: v.video_id in ^problematic_video_ids)
          |> Repo.delete_all()

        # Reset analysis fields to force re-analysis
        from(v in Video, where: v.id in ^problematic_video_ids)
        |> Repo.update_all(
          set: [
            bitrate: nil,
            video_codecs: nil,
            audio_codecs: nil,
            max_audio_channels: nil,
            atmos: nil,
            hdr: nil,
            width: nil,
            height: nil,
            frame_rate: nil,
            duration: nil,
            updated_at: DateTime.utc_now()
          ]
        )

        %{
          videos_reset: videos_reset_count,
          vmafs_deleted: vmafs_deleted_count
        }
      end,
      label: :media_reset_invalid_audio_metadata
    )
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> %{videos_reset: 0, vmafs_deleted: 0}
    end
  end

  @doc """
  Convenience function to reset all failed videos and clear their failure entries.

  This is useful for mass retry scenarios after fixing configuration issues
  or updating encoding logic. Clears the `failed` flag on videos, removes all
  associated VideoFailure records, and deletes VMAFs for failed videos since
  they were likely generated with incorrect data.

  Returns a summary of the operation.
  """
  @spec reset_all_failures() :: %{
          videos_reset: integer(),
          failures_deleted: integer(),
          vmafs_deleted: integer()
        }
  def reset_all_failures do
    write_transaction(
      fn ->
        # First, get IDs and counts of videos that will be reset
        failed_video_ids =
          from(v in Video, where: v.state == :failed, select: v.id)
          |> Repo.all()

        videos_to_reset_count = length(failed_video_ids)

        # Get count of failures that will be deleted
        failures_to_delete_count =
          from(f in VideoFailure, where: is_nil(f.resolved_at), select: count(f.id))
          |> Repo.one()

        # Delete VMAFs for failed videos (they were likely generated with bad data)
        {vmafs_deleted_count, _} =
          from(v in Vmaf, where: v.video_id in ^failed_video_ids)
          |> Repo.delete_all()

        # Reset all failed videos back to needs_analysis
        from(v in Video, where: v.state == :failed)
        |> Repo.update_all(set: [state: :needs_analysis, updated_at: DateTime.utc_now()])

        # Delete all unresolved failures
        from(f in VideoFailure, where: is_nil(f.resolved_at))
        |> Repo.delete_all()

        %{
          videos_reset: videos_to_reset_count,
          failures_deleted: failures_to_delete_count,
          vmafs_deleted: vmafs_deleted_count
        }
      end,
      label: :media_reset_all_failures
    )
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> %{videos_reset: 0, failures_deleted: 0, vmafs_deleted: 0}
    end
  end

  # Consolidated shared logic for video deletion
  defp delete_videos_by_ids(video_ids) do
    deleted_videos = fetch_dashboard_video_snapshots_by_ids(video_ids)

    delete_videos_and_vmafs(video_ids)
    |> tap(fn
      {:ok, %{vmafs_deleted: vmafs_deleted}} ->
        if vmafs_deleted > 0, do: broadcast_vmaf_mutation(:delete, vmafs_deleted)
        Enum.each(deleted_videos, &broadcast_video_mutation(:delete, &1, nil))

      _ ->
        :ok
    end)
  end

  def delete_videos_with_path(path) do
    case_insensitive_like_condition = SharedQueries.case_insensitive_like(:path, path)

    video_ids =
      from(v in Video, where: ^case_insensitive_like_condition, select: v.id) |> Repo.all()

    case delete_videos_by_ids(video_ids) do
      {:ok, %{videos_deleted: count}} -> {:ok, {count, nil}}
      err -> err
    end
  end

  @doc """
  Deletes all videos (and their VMAFs/failures) whose path starts with the given
  directory prefix. Used when a series or movie is deleted from Sonarr/Radarr.

  Returns `{:ok, count}` with the number of deleted videos, or `{:error, reason}`.
  """
  def delete_videos_under_path(dir_path) when is_binary(dir_path) do
    # Ensure trailing separator so we don't match partial directory names
    prefix = String.trim_trailing(dir_path, "/") <> "/"
    like_pattern = prefix <> "%"

    video_ids =
      from(v in Video,
        where: like(v.path, ^like_pattern),
        select: v.id
      )
      |> Repo.all()

    case video_ids do
      [] ->
        {:ok, 0}

      ids ->
        case delete_videos_by_ids(ids) do
          {:ok, _} -> {:ok, length(ids)}
          err -> err
        end
    end
  end

  @doc """
  Deletes videos whose files are confirmed missing.

  Cleanup is intentionally throttled so it does not compete aggressively with
  SQLite or remote filesystem I/O. Videos under unavailable library roots are
  skipped instead of being treated as deleted files.
  """
  def delete_videos_with_nonexistent_paths(opts \\ []) do
    Logger.info("Starting cleanup of videos with nonexistent paths...")

    cleanup_opts = missing_file_cleanup_opts(opts)
    log_unavailable_libraries(cleanup_opts.unavailable_libraries)

    deleted_count = delete_missing_files_batched(0, 0, cleanup_opts)

    Logger.info("Cleanup complete: deleted #{deleted_count} videos with nonexistent paths")
    {:ok, deleted_count}
  end

  defp delete_missing_files_batched(last_id, total_deleted, cleanup_opts) do
    batch =
      from(v in Video,
        where: v.id > ^last_id,
        order_by: [asc: v.id],
        limit: ^cleanup_opts.scan_batch_size,
        select: %{id: v.id, path: v.path, library_id: v.library_id}
      )
      |> Repo.all()

    case batch do
      [] ->
        total_deleted

      videos ->
        last_video_id = List.last(videos).id
        missing_ids = find_missing_file_ids(videos, cleanup_opts)

        new_total =
          missing_ids
          |> Enum.chunk_every(cleanup_opts.delete_batch_size)
          |> Enum.reduce(total_deleted, fn ids, acc ->
            delete_missing_batch(ids, acc, last_video_id)
          end)

        pause_missing_file_cleanup(cleanup_opts)
        delete_missing_files_batched(last_video_id, new_total, cleanup_opts)
    end
  end

  defp find_missing_file_ids(videos, cleanup_opts) do
    videos
    |> Enum.filter(&library_available?(&1, cleanup_opts.available_library_ids))
    |> Task.async_stream(
      fn video -> {video.id, file_missing?(video)} end,
      max_concurrency: cleanup_opts.file_check_concurrency,
      timeout: cleanup_opts.file_check_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {id, true}} -> [id]
      _ -> []
    end)
  end

  defp delete_missing_batch([], total_deleted, _last_id), do: total_deleted

  defp delete_missing_batch(missing_ids, total_deleted, last_id) do
    deleted_videos = fetch_dashboard_video_snapshots_by_ids(missing_ids)

    delete_videos_and_vmafs(missing_ids)
    |> case do
      {:ok, %{videos_deleted: count, vmafs_deleted: vmafs_deleted}} ->
        if vmafs_deleted > 0, do: broadcast_vmaf_mutation(:delete, vmafs_deleted)
        Enum.each(deleted_videos, &broadcast_video_mutation(:delete, &1, nil))

        Logger.info(
          "Deleted #{count} missing videos (#{total_deleted + count} total, last_id: #{last_id})"
        )

        total_deleted + count

      {:error, reason} ->
        Logger.error("Failed to delete batch: #{inspect(reason)}")
        total_deleted
    end
  end

  defp delete_videos_and_vmafs(video_ids) do
    write(
      fn ->
        Repo.transaction(fn ->
          {vmafs_deleted, _} =
            from(v in Vmaf, where: v.video_id in ^video_ids) |> Repo.delete_all()

          {videos_deleted, _} = from(v in Video, where: v.id in ^video_ids) |> Repo.delete_all()
          %{vmafs_deleted: vmafs_deleted, videos_deleted: videos_deleted}
        end)
      end,
      label: :media_delete_videos_and_vmafs
    )
  end

  defp missing_file_cleanup_opts(opts) do
    libraries = Repo.all(from(l in Library, select: %{id: l.id, path: l.path}))

    {available_library_ids, unavailable_libraries} =
      Enum.reduce(libraries, {MapSet.new(), []}, fn library, {available, unavailable} ->
        if library_root_available?(library.path) do
          {MapSet.put(available, library.id), unavailable}
        else
          {available, [library | unavailable]}
        end
      end)

    %{
      scan_batch_size:
        positive_cleanup_integer(
          opts,
          :scan_batch_size,
          :missing_file_cleanup_scan_batch_size,
          @missing_file_scan_batch_size
        ),
      delete_batch_size:
        positive_cleanup_integer(
          opts,
          :delete_batch_size,
          :missing_file_cleanup_delete_batch_size,
          @missing_file_delete_batch_size
        ),
      file_check_concurrency:
        positive_cleanup_integer(
          opts,
          :file_check_concurrency,
          :missing_file_cleanup_file_check_concurrency,
          @missing_file_check_concurrency
        ),
      file_check_timeout_ms:
        positive_cleanup_integer(
          opts,
          :file_check_timeout_ms,
          :missing_file_cleanup_file_check_timeout_ms,
          @missing_file_check_timeout_ms
        ),
      batch_pause_ms:
        non_negative_cleanup_integer(
          opts,
          :batch_pause_ms,
          :missing_file_cleanup_batch_pause_ms,
          @missing_file_batch_pause_ms
        ),
      available_library_ids: available_library_ids,
      unavailable_libraries: Enum.reverse(unavailable_libraries)
    }
  end

  defp positive_cleanup_integer(opts, opt_key, config_key, default) do
    case Keyword.get(opts, opt_key, Application.get_env(:reencodarr, config_key, default)) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp non_negative_cleanup_integer(opts, opt_key, config_key, default) do
    case Keyword.get(opts, opt_key, Application.get_env(:reencodarr, config_key, default)) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end

  defp library_available?(%{library_id: nil}, _available_library_ids), do: true

  defp library_available?(%{library_id: library_id}, available_library_ids) do
    MapSet.member?(available_library_ids, library_id)
  end

  defp library_root_available?(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> true
      {:ok, _} -> false
      {:error, _reason} -> false
    end
  end

  defp library_root_available?(_path), do: false

  defp log_unavailable_libraries([]), do: :ok

  defp log_unavailable_libraries(libraries) do
    paths = Enum.map_join(libraries, ", ", & &1.path)

    Logger.warning(
      "Skipping missing-path cleanup for #{length(libraries)} unavailable libraries: #{paths}"
    )
  end

  defp pause_missing_file_cleanup(%{batch_pause_ms: 0}), do: :ok

  defp pause_missing_file_cleanup(%{batch_pause_ms: batch_pause_ms}) do
    Process.sleep(batch_pause_ms)
  end

  defp file_missing?(%{path: path}) do
    case File.stat(path, time: :posix) do
      {:ok, _stat} ->
        false

      {:error, reason} when reason in [:enoent, :enotdir] ->
        true

      {:error, reason} ->
        Logger.debug("Skipping missing-path deletion for #{path}: #{inspect(reason)}")
        false
    end
  end

  # --- Library-related functions ---
  def list_libraries do
    Repo.all(from(l in Library))
  end

  def get_library!(id) do
    Repo.get!(Library, id)
  end

  def create_library(attrs \\ %{}) do
    write(fn -> %Library{} |> Library.changeset(attrs) |> Repo.insert() end,
      label: :media_create_library
    )
  end

  def update_library(%Library{} = l, attrs) do
    write(fn -> l |> Library.changeset(attrs) |> Repo.update() end, label: :media_update_library)
  end

  def delete_library(%Library{} = l),
    do: write(fn -> Repo.delete(l) end, label: :media_delete_library)

  def change_library(%Library{} = l, attrs \\ %{}) do
    Library.changeset(l, attrs)
  end

  # --- Vmaf-related functions ---
  def list_vmafs, do: Repo.all(Vmaf)
  def get_vmaf!(id), do: Repo.get!(Vmaf, id) |> Repo.preload(:video)

  def create_vmaf(attrs \\ %{}) do
    write(
      fn -> %Vmaf{} |> Vmaf.changeset(attrs) |> Repo.insert() end,
      label: :media_create_vmaf
    )
    |> tap(fn
      {:ok, %Vmaf{}} -> broadcast_vmaf_mutation(:insert, 1)
      _ -> :ok
    end)
  end

  @doc """
  Inserts a VMAF record, ignoring conflicts on (crf, video_id).

  Use this during CRF search line processing to safely ignore the duplicate plain-stdout
  summary line that ab-av1 emits after the INFO-level line for the same CRF value.
  Returns `{:ok, vmaf}` on insert or `{:ok, :skipped}` when a record already exists.
  """
  def insert_vmaf(attrs), do: vmaf_operation(attrs, on_conflict: :nothing)

  def upsert_vmaf(attrs) do
    vmaf_operation(attrs, on_conflict: {:replace_all_except, [:id, :video_id, :inserted_at]})
  end

  defp vmaf_operation(attrs, opts) do
    video_id = Map.get(attrs, "video_id") || Map.get(attrs, :video_id)

    with {:ok, video_id} <- validate_video_id(video_id),
         %Video{} = video <- get_video(video_id) do
      attrs_with_savings = maybe_calculate_savings(attrs, video)
      changeset = Vmaf.changeset(%Vmaf{}, attrs_with_savings)
      existing_vmaf? = vmaf_conflict_exists?(changeset)

      result =
        write(
          fn ->
            Repo.insert(changeset, Keyword.merge([conflict_target: [:crf, :video_id]], opts))
          end,
          label: :media_vmaf_operation
        )

      handle_vmaf_insert_result(result, existing_vmaf?)
    else
      :error ->
        Logger.error("Attempted VMAF operation with invalid video_id type: #{inspect(attrs)}")
        {:error, :invalid_video_id}

      nil ->
        Logger.error("Attempted VMAF operation with missing video_id: #{inspect(attrs)}")
        {:error, :invalid_video_id}
    end
  end

  defp handle_vmaf_insert_result({:ok, %Vmaf{id: nil}}, _existing_vmaf?), do: {:ok, :skipped}

  defp handle_vmaf_insert_result({:ok, %Vmaf{}} = ok, existing_vmaf?) do
    if not existing_vmaf?, do: broadcast_vmaf_mutation(:insert, 1)
    ok
  end

  defp handle_vmaf_insert_result({:error, _} = err, _existing_vmaf?), do: err

  defp validate_video_id(id) when is_integer(id) or is_binary(id), do: {:ok, id}
  defp validate_video_id(_), do: :error

  # Calculate savings if not already provided and we have the necessary data
  defp maybe_calculate_savings(attrs, %Video{} = video) do
    case {Map.get(attrs, "savings"), Map.get(attrs, "percent")} do
      {nil, percent} when is_number(percent) or is_binary(percent) ->
        case video do
          %Video{size: size} when is_integer(size) and size > 0 ->
            savings = calculate_vmaf_savings(percent, size)
            Map.put(attrs, "savings", savings)

          _ ->
            attrs
        end

      _ ->
        attrs
    end
  end

  # Calculate estimated space savings in bytes based on percent and video size
  defp calculate_vmaf_savings(percent, video_size) when is_binary(percent) do
    case Parsers.parse_float_exact(percent) do
      {:ok, percent_float} -> calculate_vmaf_savings(percent_float, video_size)
      {:error, _} -> nil
    end
  end

  defp calculate_vmaf_savings(percent, video_size)
       when is_number(percent) and is_number(video_size) and
              percent > 0 and percent <= 100 do
    # Savings = (100 - percent) / 100 * original_size
    round((100 - percent) / 100 * video_size)
  end

  defp calculate_vmaf_savings(_, _), do: nil

  def update_vmaf(%Vmaf{} = vmaf, attrs) do
    write(fn -> vmaf |> Vmaf.changeset(attrs) |> Repo.update() end, label: :media_update_vmaf)
  end

  def delete_vmaf(%Vmaf{} = vmaf) do
    write(fn -> Repo.delete(vmaf) end, label: :media_delete_vmaf)
    |> tap(fn
      {:ok, %Vmaf{}} -> broadcast_vmaf_mutation(:delete, 1)
      _ -> :ok
    end)
  end

  @doc """
  Deletes all VMAFs for a given video ID.

  ## Parameters
    - `video_id`: integer video ID

  ## Returns
    - `{count, nil}` where count is the number of deleted VMAFs

  ## Examples
      iex> Media.delete_vmafs_for_video(123)
      {3, nil}
  """
  def delete_vmafs_for_video(video_id) when is_integer(video_id) do
    write(
      fn ->
        from(v in Vmaf, where: v.video_id == ^video_id)
        |> Repo.delete_all()
      end,
      label: :media_delete_vmafs_for_video
    )
    |> tap(fn
      {count, _} when count > 0 -> broadcast_vmaf_mutation(:delete, count)
      _ -> :ok
    end)
  end

  @doc """
  Forces complete re-analysis of a video by resetting all analysis data and manually queuing it.

  This function:
  1. Deletes all VMAFs for the video
  2. Resets video analysis fields (bitrate, etc.)
  3. Manually adds the video to the analyzer queue
  4. Returns the video path for verification

  ## Parameters
    - `video_id`: integer video ID

  ## Returns
    - `{:ok, video_path}` on success
    - `{:error, reason}` if video not found

  ## Examples
      iex> Media.force_reanalyze_video(9008028)
      {:ok, "/path/to/video.mkv"}
  """
  def force_reanalyze_video(video_id) when is_integer(video_id) do
    case get_video(video_id) do
      nil ->
        {:error, "Video #{video_id} not found"}

      video ->
        write_transaction(
          fn ->
            # 1. Delete all VMAFs
            delete_vmafs_for_video(video_id)

            # 2. Reset analysis fields to force re-analysis
            update_video(video, %{
              bitrate: nil,
              video_codecs: nil,
              audio_codecs: nil,
              max_audio_channels: nil,
              atmos: nil,
              hdr: nil,
              width: nil,
              height: nil,
              frame_rate: nil,
              duration: nil
            })

            # 3. Manually trigger analysis using Broadway dispatch
            AnalyzerBroadway.dispatch_available()

            video.path
          end,
          label: :media_force_reanalyze_video
        )
        |> case do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def change_vmaf(%Vmaf{} = vmaf, attrs \\ %{}) do
    Vmaf.changeset(vmaf, attrs)
  end

  def chosen_vmaf_exists?(%{id: id}),
    do: Repo.exists?(from v in Video, where: v.id == ^id and not is_nil(v.chosen_vmaf_id))

  @doc """
  Checks if any VMAF records exist for a video (regardless of chosen status).
  Used to validate that CRF search actually produced results.
  """
  def vmaf_records_exist?(%{id: id}),
    do: Repo.exists?(from v in Vmaf, where: v.video_id == ^id)

  # Consolidated shared logic for chosen VMAF queries
  defp query_chosen_vmafs do
    from vid in Video,
      join: v in Vmaf,
      on: vid.chosen_vmaf_id == v.id,
      where: vid.state == :crf_searched,
      select: %{v | video: vid},
      order_by: [asc: v.percent, asc: v.time]
  end

  # Function to list all chosen VMAFs
  def list_chosen_vmafs do
    Repo.all(query_chosen_vmafs())
  end

  # Function to get the chosen VMAF for a specific video
  def get_chosen_vmaf_for_video(%Video{id: video_id}) do
    Repo.one(
      from vid in Video,
        join: v in Vmaf,
        on: vid.chosen_vmaf_id == v.id,
        where: vid.id == ^video_id and vid.state == :crf_searched,
        select: %{v | video: vid}
    )
  end

  # --- Queue helpers ---

  def get_next_for_encoding_by_time do
    result =
      Repo.one(
        from vid in Video,
          join: v in Vmaf,
          on: vid.chosen_vmaf_id == v.id,
          where: vid.state == :crf_searched,
          order_by: [fragment("? DESC NULLS LAST", v.savings), asc: v.time],
          limit: 1,
          select: %{v | video: vid}
      )

    if result, do: [result], else: []
  end

  @doc false
  def dashboard_video_snapshot(nil), do: nil

  def dashboard_video_snapshot(%Video{} = video) do
    %{
      id: video.id,
      path: video.path,
      state: video.state,
      size: video.size,
      original_size: video.original_size,
      priority: video.priority,
      chosen_vmaf_id: video.chosen_vmaf_id,
      chosen_vmaf_savings: snapshot_chosen_vmaf_savings(video),
      inserted_at: video.inserted_at,
      updated_at: video.updated_at
    }
  end

  @doc false
  def fetch_dashboard_video_snapshot_by_path(path) when is_binary(path) do
    Repo.one(
      from(v in Video,
        left_join: chosen in Vmaf,
        on: chosen.id == v.chosen_vmaf_id,
        where: v.path == ^path,
        select: %{
          id: v.id,
          path: v.path,
          state: v.state,
          size: v.size,
          original_size: v.original_size,
          priority: v.priority,
          chosen_vmaf_id: v.chosen_vmaf_id,
          chosen_vmaf_savings: chosen.savings,
          inserted_at: v.inserted_at,
          updated_at: v.updated_at
        }
      )
    )
  end

  def fetch_dashboard_video_snapshot_by_path(_), do: nil

  @doc false
  def fetch_dashboard_video_snapshot_by_id(id) when is_integer(id) do
    Repo.one(
      from(v in Video,
        left_join: chosen in Vmaf,
        on: chosen.id == v.chosen_vmaf_id,
        where: v.id == ^id,
        select: %{
          id: v.id,
          path: v.path,
          state: v.state,
          size: v.size,
          original_size: v.original_size,
          priority: v.priority,
          chosen_vmaf_id: v.chosen_vmaf_id,
          chosen_vmaf_savings: chosen.savings,
          inserted_at: v.inserted_at,
          updated_at: v.updated_at
        }
      )
    )
  end

  def fetch_dashboard_video_snapshot_by_id(_), do: nil

  @doc false
  def fetch_dashboard_video_snapshots_by_ids(video_ids) when is_list(video_ids) do
    Repo.all(
      from(v in Video,
        left_join: chosen in Vmaf,
        on: chosen.id == v.chosen_vmaf_id,
        where: v.id in ^video_ids,
        select: %{
          id: v.id,
          path: v.path,
          state: v.state,
          size: v.size,
          original_size: v.original_size,
          priority: v.priority,
          chosen_vmaf_id: v.chosen_vmaf_id,
          chosen_vmaf_savings: chosen.savings,
          inserted_at: v.inserted_at,
          updated_at: v.updated_at
        }
      )
    )
  end

  @doc false
  def broadcast_video_mutation(action, old_video, new_video)
      when action in [:insert, :update, :delete] do
    if action != :update or old_video != new_video do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "video_state_transitions",
        {:video_mutated, %{action: action, old_video: old_video, new_video: new_video}}
      )
    end

    :ok
  end

  @doc false
  def broadcast_vmaf_mutation(action, count)
      when action in [:insert, :delete] and is_integer(count) and count > 0 do
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "video_state_transitions",
      {:vmaf_mutated, %{action: action, count: count}}
    )

    :ok
  end

  def mark_vmaf_as_chosen(video_id, crf) do
    case parse_crf(crf) do
      {:ok, crf_float} -> do_mark_vmaf_as_chosen(video_id, crf_float)
      {:error, _} -> {:error, :invalid_crf}
    end
  end

  defp do_mark_vmaf_as_chosen(video_id, crf_float) do
    case Repo.one(
           from(v in Vmaf,
             where: v.video_id == ^video_id and v.crf == ^crf_float,
             select: v.id,
             limit: 1
           )
         ) do
      nil ->
        {:error, :no_vmaf_matched}

      vmaf_id ->
        old_video = fetch_dashboard_video_snapshot_by_id(video_id)

        {1, _} =
          write(
            fn ->
              from(v in Video, where: v.id == ^video_id)
              |> Repo.update_all(set: [chosen_vmaf_id: vmaf_id, updated_at: DateTime.utc_now()])
            end,
            label: :media_mark_vmaf_as_chosen
          )

        broadcast_video_mutation(
          :update,
          old_video,
          fetch_dashboard_video_snapshot_by_id(video_id)
        )

        {:ok, vmaf_id}
    end
  end

  @doc """
  Auto-chooses the best VMAF for a video when no success line was parsed.

  Selects the VMAF with the highest score that meets the video's VMAF target,
  preferring smaller file sizes (lower percent) among qualifying results.
  Falls back to the highest-scoring VMAF if none meet the target.

  Returns `{:ok, vmaf}` or `{:error, :no_vmafs}`.
  """
  def choose_best_vmaf(%Video{id: video_id} = video) do
    target = Rules.vmaf_target(video)

    # Prefer: meets target, lowest percent (smallest file), then highest score
    best =
      Repo.one(
        from v in Vmaf,
          where: v.video_id == ^video_id and v.score >= ^target,
          order_by: [asc: v.percent, desc: v.score],
          limit: 1
      )

    # Fallback: highest score regardless of target
    best =
      best ||
        Repo.one(
          from v in Vmaf,
            where: v.video_id == ^video_id,
            order_by: [desc: v.score],
            limit: 1
        )

    case best do
      nil ->
        {:error, :no_vmafs}

      %Vmaf{id: vmaf_id} ->
        old_video = fetch_dashboard_video_snapshot_by_id(video_id)

        {1, _} =
          write(
            fn ->
              from(v in Video, where: v.id == ^video_id)
              |> Repo.update_all(set: [chosen_vmaf_id: vmaf_id, updated_at: DateTime.utc_now()])
            end,
            label: :media_choose_best_vmaf
          )

        broadcast_video_mutation(
          :update,
          old_video,
          fetch_dashboard_video_snapshot_by_id(video_id)
        )

        {:ok, best}
    end
  end

  defp parse_crf(crf) when is_number(crf), do: {:ok, crf}

  defp parse_crf(crf) when is_binary(crf) do
    Parsers.parse_float_exact(crf)
  end

  def list_videos_awaiting_crf_search do
    from(v in Video,
      left_join: vmafs in assoc(v, :vmafs),
      where: is_nil(vmafs.id) and v.state == :analyzed,
      select: v
    )
    |> Repo.all()
  end

  def get_video(id) do
    Repo.get(Video, id)
  end

  @spec fetch_video(integer()) :: {:ok, Video.t()} | :not_found
  def fetch_video(id) when is_integer(id) do
    case Repo.get(Video, id) do
      %Video{} = video -> {:ok, video}
      nil -> :not_found
    end
  end

  def get_video_by_service_id(service_id, service_type)
      when is_binary(service_id) or is_integer(service_id) do
    case Repo.one(
           from v in Video, where: v.service_id == ^service_id and v.service_type == ^service_type
         ) do
      nil -> {:error, :not_found}
      video -> {:ok, video}
    end
  end

  def get_video_by_service_id(nil, _service_type), do: {:error, :invalid_service_id}

  def count_videos do
    Repo.aggregate(Video, :count, :id)
  end

  @doc """
  List videos with pagination, optional state filter, and search.
  Returns {videos, %Flop.Meta{}}.
  """
  @spec list_videos_paginated(keyword()) :: {[Video.t()], Flop.Meta.t()}
  def list_videos_paginated(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    state_filter = Keyword.get(opts, :state, nil)
    search = Keyword.get(opts, :search, nil)
    sort_by = Keyword.get(opts, :sort_by, :updated_at)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)
    service_type = Keyword.get(opts, :service_type, nil)
    hdr = Keyword.get(opts, :hdr, nil)

    filters = build_flop_filters(state_filter, search, service_type)

    flop_params = %{
      page: page,
      page_size: per_page,
      order_by: [sort_by],
      order_directions: [sort_dir],
      filters: filters
    }

    base_query = from(v in Video) |> maybe_filter_hdr(hdr)

    case Flop.validate_and_run(base_query, flop_params, for: Video) do
      {:ok, {videos, meta}} ->
        videos = Repo.preload(videos, :chosen_vmaf)
        {videos, meta}

      {:error, _meta} ->
        {[], %Flop.Meta{flop: %Flop{}, schema: Video}}
    end
  end

  @doc "Returns a map of %{state => count} for all video states."
  @spec count_videos_by_state() :: %{atom() => non_neg_integer()}
  def count_videos_by_state do
    from(v in Video, group_by: v.state, select: {v.state, count(v.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp assign_priorities(prioritized_ids, queueable_by_id, max_priority, total) do
    prioritized_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {id, index} ->
      video = Map.fetch!(queueable_by_id, id)
      new_priority = max_priority + (total - index + 1)
      persist_priority(video, new_priority)
    end)
  end

  defp persist_priority(video, new_priority) do
    case update_video(video, %{priority: new_priority}) do
      {:ok, _updated_video} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp highest_queue_priority do
    from(v in Video,
      where: v.state in ^@queueable_states,
      select: max(v.priority)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp build_flop_filters(state_filter, search, service_type) do
    []
    |> maybe_add_flop_filter(:state, :==, state_filter)
    |> maybe_add_flop_filter(:path, :like, search)
    |> maybe_add_flop_filter(:service_type, :==, service_type)
  end

  defp maybe_add_flop_filter(filters, _field, _op, nil), do: filters
  defp maybe_add_flop_filter(filters, _field, _op, ""), do: filters

  defp maybe_add_flop_filter(filters, field, op, value) do
    [%{field: field, op: op, value: value} | filters]
  end

  defp maybe_filter_hdr(query, nil), do: query
  defp maybe_filter_hdr(query, true), do: from(v in query, where: not is_nil(v.hdr))
  defp maybe_filter_hdr(query, false), do: from(v in query, where: is_nil(v.hdr))

  def get_videos_in_library(library_id) do
    Repo.all(from v in Video, where: v.library_id == ^library_id)
  end

  def get_vmafs_for_video(video_id) do
    Repo.all(from v in Vmaf, where: v.video_id == ^video_id)
  end

  def delete_unchosen_vmafs do
    write_transaction(
      fn ->
        # Get video_ids that have vmafs but none are chosen
        video_ids_with_no_chosen_vmafs =
          videos_with_no_chosen_vmafs_query()
          |> Repo.all()

        # Delete all vmafs for those video_ids
        from(v in Vmaf, where: v.video_id in ^video_ids_with_no_chosen_vmafs)
        |> Repo.delete_all()
      end,
      label: :media_delete_unchosen_vmafs
    )
    |> tap(fn
      {:ok, {count, _}} when count > 0 -> broadcast_vmaf_mutation(:delete, count)
      _ -> :ok
    end)
  end

  @doc """
  Reset all videos for reanalysis by clearing their bitrate.
  This is much more efficient than calling Analyzer.reanalyze_video/1 for each video.
  Videos will be automatically picked up by the analyzer when there's demand.
  VMAFs will be deleted automatically when videos are re-analyzed and their properties change.
  """
  def reset_all_videos_for_reanalysis do
    write(
      fn ->
        from(v in Video,
          where: v.state not in [:encoded, :failed],
          update: [set: [bitrate: nil]]
        )
        |> Repo.update_all([])
      end,
      label: :media_reset_all_videos_for_reanalysis
    )
  end

  @doc """
  Reset videos for reanalysis in batches to avoid overwhelming the Broadway queue.
  VMAFs will be deleted automatically when videos are re-analyzed and their properties change.
  """
  def reset_videos_for_reanalysis_batched(batch_size \\ 1000) do
    total =
      Stream.unfold(0, fn _offset ->
        batch_ids =
          from(v in Video,
            where: v.state not in [:encoded, :failed] and not is_nil(v.bitrate),
            limit: ^batch_size,
            select: v.id
          )
          |> Repo.all()

        next_reanalysis_batch(batch_ids)
      end)
      |> Enum.sum()

    Logger.info("Completed resetting #{total} videos for reanalysis")
    total
  end

  defp broadcast_upserted_video({:ok, %Video{} = video}, old_video) do
    action = if old_video, do: :update, else: :insert

    broadcast_video_mutation(
      action,
      old_video,
      fetch_dashboard_video_snapshot_by_id(video.id)
    )
  end

  defp broadcast_upserted_video(_result, _old_video), do: :ok

  defp next_reanalysis_batch([]), do: nil

  defp next_reanalysis_batch(batch_ids) do
    {count, _} =
      write(
        fn ->
          from(v in Video, where: v.id in ^batch_ids, update: [set: [bitrate: nil]])
          |> Repo.update_all([])
        end,
        label: :media_reset_videos_for_reanalysis_batch
      )

    Logger.info("Reset batch of #{count} videos for reanalysis")
    Process.sleep(100)
    {count, 0}
  end

  @doc """
  Reset all failed videos to not failed in a single bulk operation.
  """
  def reset_failed_videos do
    write(
      fn ->
        from(v in Video,
          where: v.state == :failed,
          update: [set: [state: :needs_analysis]]
        )
        |> Repo.update_all([])
      end,
      label: :media_reset_failed_videos
    )
  end

  @doc """
  Reset all videos to needs_analysis state for complete reprocessing.
  This will force all videos to go through analysis again.
  """
  def reset_all_videos_to_needs_analysis do
    write(
      fn ->
        from(v in Video,
          update: [set: [state: :needs_analysis, bitrate: nil]]
        )
        |> Repo.update_all([])
      end,
      label: :media_reset_all_videos_to_needs_analysis
    )
  end

  @doc """
  Force trigger analysis of a specific video for debugging.
  """
  def debug_force_analyze_video(video_path) when is_binary(video_path) do
    case get_video_by_path(video_path) do
      {:ok, %{path: _path, service_id: _service_id, service_type: _service_type} = video} ->
        Logger.info("🐛 Force analyzing video: #{video_path}")

        # Trigger Broadway dispatch instead of old compatibility API
        result1 = AnalyzerBroadway.dispatch_available()

        # Delete all VMAFs and reset analysis fields to force re-analysis
        delete_vmafs_for_video(video.id)

        update_video(video, %{
          bitrate: nil,
          duration: nil,
          frame_rate: nil,
          video_codecs: nil,
          audio_codecs: nil,
          max_audio_channels: nil,
          resolution: nil,
          file_size: nil
        })

        # Use state machine for state transition
        mark_as_needs_analysis(video)

        %{
          video: video,
          dispatch_result: result1,
          broadway_running: AnalyzerBroadway.running?()
        }

      {:error, :not_found} ->
        {:error, "Video not found at path: #{video_path}"}
    end
  end

  @doc """
  Fetches the dashboard video stats component.
  """
  @spec fetch_dashboard_video_stats(integer()) :: {:ok, map()} | {:error, term()}
  def fetch_dashboard_video_stats(timeout \\ 15_000) do
    fetch_dashboard_component("video stats", fn ->
      Repo.one(SharedQueries.video_stats_query(), timeout: timeout) || get_default_video_stats()
    end)
  end

  @doc """
  Fetches dashboard fields that are not maintained incrementally in Dashboard.State.
  """
  @spec fetch_dashboard_metadata_stats(integer()) :: {:ok, map()} | {:error, term()}
  def fetch_dashboard_metadata_stats(timeout \\ 15_000) do
    fetch_dashboard_component("metadata stats", fn ->
      Repo.one(SharedQueries.dashboard_metadata_stats_query(), timeout: timeout) ||
        %{
          avg_duration_minutes: 0.0,
          most_recent_video_update: nil,
          most_recent_inserted_video: nil
        }
    end)
  end

  @doc """
  Fetches the dashboard library size in GiB.
  """
  @spec fetch_dashboard_total_size_gb(integer()) :: {:ok, float()} | {:error, term()}
  def fetch_dashboard_total_size_gb(timeout \\ 15_000) do
    fetch_dashboard_component("total size", fn ->
      Repo.one(SharedQueries.dashboard_total_size_query(), timeout: timeout) || 0.0
    end)
  end

  @doc """
  Fetches the dashboard savings component in GiB.
  """
  @spec fetch_dashboard_savings_gb(integer()) :: {:ok, float()} | {:error, term()}
  def fetch_dashboard_savings_gb(timeout \\ 15_000) do
    fetch_dashboard_component("savings", fn ->
      encoded_savings =
        Repo.one(SharedQueries.encoded_video_savings_query(), timeout: timeout) ||
          %{total_savings_gb: 0.0}

      predicted_savings =
        Repo.one(SharedQueries.predicted_video_savings_query(), timeout: timeout) ||
          %{total_savings_gb: 0.0}

      (encoded_savings.total_savings_gb || 0.0) + (predicted_savings.total_savings_gb || 0.0)
    end)
  end

  @doc """
  Fetches the dashboard VMAF stats component.
  """
  @spec fetch_dashboard_vmaf_stats(integer()) :: {:ok, map()} | {:error, term()}
  def fetch_dashboard_vmaf_stats(timeout \\ 15_000) do
    fetch_dashboard_component("vmaf stats", fn ->
      Repo.one(SharedQueries.vmaf_stats_query(), timeout: timeout) || get_default_vmaf_stats()
    end)
  end

  @doc """
  Get dashboard statistics with safe timeout handling.

  Returns merged stats or defaults on timeout/error/interruption.
  """
  @spec get_dashboard_stats(integer()) :: map()
  def get_dashboard_stats(timeout \\ 15_000) do
    stats = get_default_stats()

    stats =
      case fetch_dashboard_video_stats(timeout) do
        {:ok, video_stats} -> Map.merge(stats, video_stats)
        {:error, _reason} -> stats
      end

    stats =
      case fetch_dashboard_total_size_gb(timeout) do
        {:ok, total_size_gb} -> Map.put(stats, :total_size_gb, total_size_gb)
        {:error, _reason} -> stats
      end

    stats =
      case fetch_dashboard_savings_gb(timeout) do
        {:ok, total_savings_gb} -> Map.put(stats, :total_savings_gb, total_savings_gb)
        {:error, _reason} -> stats
      end

    case fetch_dashboard_vmaf_stats(timeout) do
      {:ok, vmaf_stats} -> Map.merge(stats, vmaf_stats)
      {:error, _reason} -> stats
    end
  end

  defp fetch_dashboard_component(label, fun) do
    {:ok, fun.()}
  rescue
    e in DBConnection.ConnectionError ->
      Logger.warning(
        "Dashboard #{label} query failed with connection error: #{Exception.message(e)}"
      )

      {:error, e}

    e in Exqlite.Error ->
      if interrupted_dashboard_query?(e) do
        Logger.debug("Dashboard #{label} query interrupted, using fallback")
      else
        Logger.warning("Dashboard #{label} query failed: #{Exception.message(e)}")
      end

      {:error, e}
  catch
    :exit, {:timeout, _} ->
      Logger.debug("Dashboard #{label} query timed out, using fallback")
      {:error, :timeout}

    :exit, {%DBConnection.ConnectionError{} = e, _} ->
      Logger.warning(
        "Dashboard #{label} query failed with connection error: #{Exception.message(e)}"
      )

      {:error, e}

    :exit, reason ->
      Logger.debug("Dashboard #{label} query exited, using fallback")
      {:error, reason}
  end

  defp interrupted_dashboard_query?(%Exqlite.Error{message: message}) do
    String.downcase(to_string(message)) == "interrupted"
  end

  defp get_default_video_stats do
    %{
      total_videos: 0,
      total_size_gb: 0.0,
      needs_analysis: 0,
      analyzed: 0,
      crf_searching: 0,
      crf_searched: 0,
      encoding: 0,
      encoded: 0,
      failed: 0,
      avg_duration_minutes: 0.0,
      most_recent_video_update: nil,
      most_recent_inserted_video: nil,
      encoding_queue_count: 0,
      total_savings_gb: 0.0
    }
  end

  defp get_default_vmaf_stats do
    %{
      total_vmafs: 0,
      chosen_vmafs: 0
    }
  end

  @doc "Returns default (zeroed) dashboard stats map."
  def get_default_stats do
    Map.merge(get_default_video_stats(), get_default_vmaf_stats())
  end

  @doc """
  Debug function to show how the encoding queue alternates between libraries.
  """
  def debug_encoding_queue_by_library(limit \\ 10) do
    videos = query_videos_ready_for_encoding(limit)

    videos
    |> Enum.with_index()
    |> Enum.map(fn {vmaf, index} ->
      %{
        position: index + 1,
        library_id: vmaf.video.library_id,
        video_path: vmaf.video.path,
        percent: vmaf.percent,
        savings: vmaf.savings
      }
    end)
  end

  @doc """
  Diagnostic function to test inserting a video path and report exactly what happened.

  This function attempts to create or upsert a video with minimal required data and
  provides detailed feedback about the operation including any validation errors,
  constraint violations, or success messages.

  ## Examples

      iex> Reencodarr.Media.test_insert_path("/path/to/test/video.mkv")
      %{
        success: true,
        operation: "insert",
        video_id: 123,
        messages: ["Successfully inserted new video"],
        path: "/path/to/test/video.mkv",
        library_id: 1,
        errors: []
      }

      iex> Reencodarr.Media.test_insert_path("/path/to/existing/video.mkv")
      %{
        success: true,
        operation: "upsert",
        video_id: 124,
        messages: ["Video already existed, updated successfully"],
        path: "/path/to/existing/video.mkv",
        library_id: 1,
        errors: []
      }
  """
  @spec test_insert_path(String.t(), map()) :: %{
          success: boolean(),
          operation: String.t(),
          video_id: integer() | nil,
          messages: [String.t()],
          path: String.t(),
          library_id: integer() | nil,
          errors: [String.t()],
          file_exists: boolean(),
          had_existing_video: boolean()
        }
  def test_insert_path(path, additional_attrs \\ %{}) when is_binary(path) do
    Logger.info("Testing path insertion: #{path}")

    # Gather initial diagnostics
    diagnostics = gather_path_diagnostics(path, additional_attrs)

    # Attempt the upsert operation
    result = attempt_video_upsert(diagnostics)

    # Build final result with all diagnostics
    build_final_result(result, diagnostics)
  end

  defp gather_path_diagnostics(path, additional_attrs) do
    file_exists = File.exists?(path)
    existing_video = get_video_by_path(path)

    # Find library for this path - same logic as in VideoUpsert
    library_id =
      Repo.one(
        from l in Library,
          where: fragment("? LIKE ? || '%'", ^path, l.path),
          order_by: [desc: fragment("LENGTH(?)", l.path)],
          limit: 1,
          select: l.id
      )

    attrs = build_base_attrs(path, library_id) |> Map.merge(additional_attrs)

    {messages, errors} = build_diagnostic_messages(file_exists, existing_video, library_id, path)

    %{
      path: path,
      file_exists: file_exists,
      existing_video: existing_video,
      library_id: library_id,
      attrs: attrs,
      messages: messages,
      errors: errors
    }
  end

  defp build_base_attrs(path, library_id) do
    %{
      "path" => path,
      "library_id" => library_id,
      "service_type" => "sonarr",
      "service_id" => "test_#{System.system_time(:second)}",
      "size" => 1_000_000,
      "duration" => 3600.0,
      "video_codecs" => ["H.264"],
      "audio_codecs" => ["AAC"],
      "state" => "needs_analysis",
      "failed" => false
    }
  end

  defp build_diagnostic_messages(file_exists, existing_video, library_id, path) do
    messages = []
    errors = []

    {messages, errors} = add_file_existence_messages(file_exists, path, messages, errors)
    messages = add_existing_video_messages(existing_video, messages)
    {messages, errors} = add_library_messages(library_id, path, messages, errors)

    {messages, errors}
  end

  defp add_file_existence_messages(true, _path, messages, errors) do
    {["File exists on filesystem" | messages], errors}
  end

  defp add_file_existence_messages(false, path, messages, errors) do
    {["File does not exist on filesystem" | messages],
     ["File does not exist on filesystem: #{path}" | errors]}
  end

  defp add_existing_video_messages(existing_video, messages) do
    case existing_video do
      {:error, :not_found} -> ["No existing video found in database" | messages]
      {:ok, %Video{id: id}} -> ["Found existing video with ID: #{id}" | messages]
    end
  end

  defp add_library_messages(library_id, _path, messages, errors) do
    case library_id do
      nil ->
        {["No matching library found for path" | messages],
         ["No matching library found for path" | errors]}

      lib_id ->
        {["Found library ID: #{lib_id}" | messages], errors}
    end
  end

  defp attempt_video_upsert(diagnostics) do
    case upsert_video(diagnostics.attrs) do
      {:ok, video} ->
        operation = if match?({:ok, _}, diagnostics.existing_video), do: "upsert", else: "insert"

        %{
          success: true,
          operation: operation,
          video_id: video.id,
          messages: [
            "Successfully #{operation}ed video with ID: #{video.id}" | diagnostics.messages
          ],
          errors: diagnostics.errors
        }

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_errors =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

        %{
          success: false,
          operation: "failed",
          video_id: nil,
          messages: ["Changeset validation failed" | diagnostics.messages],
          errors: changeset_errors ++ diagnostics.errors
        }

      {:error, reason} ->
        %{
          success: false,
          operation: "failed",
          video_id: nil,
          messages: ["Operation failed with error" | diagnostics.messages],
          errors: ["Error: #{inspect(reason)}" | diagnostics.errors]
        }
    end
  end

  defp build_final_result(result, diagnostics) do
    final_result =
      result
      |> Map.put(:path, diagnostics.path)
      |> Map.put(:library_id, diagnostics.library_id)
      |> Map.put(:file_exists, diagnostics.file_exists)
      |> Map.put(:had_existing_video, match?({:ok, %Video{}}, diagnostics.existing_video))
      |> Map.put(:messages, Enum.reverse(result.messages))
      |> Map.put(:errors, Enum.reverse(result.errors))

    Logger.info("Test result: #{if result.success, do: "SUCCESS", else: "FAILED"}")

    log_test_result_details(result)

    final_result
  end

  # Helper function to log test result details
  defp log_test_result_details(%{success: true, video_id: video_id, operation: operation}) do
    Logger.info("   Video ID: #{video_id}, Operation: #{operation}")
  end

  defp log_test_result_details(%{success: false, errors: errors}) do
    Logger.warning("   Errors: #{Enum.join(errors, ", ")}")
  end

  defp snapshot_chosen_vmaf_savings(%Video{} = video) do
    case Map.get(video, :chosen_vmaf) do
      %Vmaf{savings: savings} -> savings
      _ -> nil
    end
  end

  defp vmaf_conflict_exists?(changeset) do
    case {Ecto.Changeset.get_field(changeset, :video_id),
          Ecto.Changeset.get_field(changeset, :crf)} do
      {video_id, crf} when is_integer(video_id) and is_number(crf) ->
        Repo.exists?(from(v in Vmaf, where: v.video_id == ^video_id and v.crf == ^crf))

      _ ->
        false
    end
  end
end
