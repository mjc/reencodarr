defmodule Reencodarr.Media do
  import Ecto.Query, warn: false
  alias Reencodarr.Analyzer.Producer
  alias Reencodarr.Media.{Library, Video, Vmaf}
  alias Reencodarr.Repo
  require Logger

  @moduledoc "Handles media-related operations and database interactions."

  # --- Video-related functions ---
  def list_videos, do: Repo.all(from v in Video, order_by: [desc: v.updated_at])
  def get_video!(id), do: Repo.get!(Video, id)
  def get_video_by_path(path), do: Repo.one(from v in Video, where: v.path == ^path)
  def video_exists?(path), do: Repo.exists?(from v in Video, where: v.path == ^path)

  def find_videos_by_path_wildcard(pattern),
    do: Repo.all(from v in Video, where: like(v.path, ^pattern))

  def get_next_crf_search(limit \\ 10) do
    Repo.all(
      from v in Video,
        left_join: m in Vmaf,
        on: m.video_id == v.id,
        where:
          is_nil(m.id) and v.reencoded == false and v.failed == false and
            not fragment(
              "EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))",
              v.audio_codecs,
              "%opus%"
            ) and
            not fragment(
              "EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))",
              v.video_codecs,
              "%av1%"
            ),
        order_by: [
          desc: v.bitrate,
          desc: v.size,
          asc: v.updated_at
        ],
        limit: ^limit,
        select: v
    )
  end

  def get_next_for_analysis(limit \\ 10) do
    # Get videos that need analysis (bitrate = 0 or nil)
    videos_needing_analysis =
      Repo.all(
        from v in Video,
          where: (v.bitrate == 0 or is_nil(v.bitrate)) and v.failed == false,
          order_by: [
            desc: v.size,
            asc: v.updated_at
          ],
          limit: ^limit,
          select: %{
            path: v.path,
            service_id: v.service_id,
            service_type: v.service_type,
            force_reanalyze: false
          }
      )

    # Convert to the format expected by the consumer
    Enum.map(videos_needing_analysis, fn video ->
      %{
        path: video.path,
        service_id: video.service_id,
        service_type: video.service_type,
        force_reanalyze: video.force_reanalyze
      }
    end)
  end

  # Renamed `base_query_for_videos` to `query_videos_by_criteria` for better understanding
  defp query_videos_by_criteria(limit) do
    Repo.all(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.reencoded == false and vid.failed == false,
        order_by: [
          asc: v.percent,
          asc: v.time,
          asc: v.size
        ],
        limit: ^limit,
        preload: [:video]
    )
  end

  def list_videos_by_estimated_percent(limit \\ 10) do
    query_videos_by_criteria(limit)
  end

  def get_next_for_encoding(limit \\ 1) do
    case limit do
      1 -> query_videos_by_criteria(1) |> List.first()
      _ -> query_videos_by_criteria(limit)
    end
  end

  def create_video(attrs \\ %{}), do: %Video{} |> Video.changeset(attrs) |> Repo.insert()

  def upsert_video(attrs) do
    result =
      attrs
      |> ensure_library_id()
      |> Video.changeset()
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at, :reencoded, :failed]},
        conflict_target: :path
      )

    case result do
      {:ok, video} ->
        Reencodarr.Telemetry.emit_video_upserted(video)

      _ ->
        :ok
    end

    result
  end

  defp ensure_library_id(%{library_id: nil} = attrs),
    do: %{attrs | library_id: find_library_id(attrs[:path])}

  defp ensure_library_id(attrs), do: attrs

  defp find_library_id(path),
    do:
      from(l in Library, where: like(^path, fragment("concat(?, '%')", l.path)), select: l.id)
      |> Repo.one()

  def update_video(%Video{} = video, attrs), do: video |> Video.changeset(attrs) |> Repo.update()
  def delete_video(%Video{} = video), do: Repo.delete(video)
  def change_video(%Video{} = video, attrs \\ %{}), do: Video.changeset(video, attrs)

  def update_video_status(%Video{} = video, attrs),
    do: video |> Video.changeset(attrs) |> Repo.update()

  def mark_as_reencoded(%Video{} = video),
    do: update_video_status(video, %{reencoded: true, failed: false})

  def mark_as_failed(%Video{} = video), do: update_video_status(video, %{failed: true})
  def most_recent_video_update, do: Repo.one(from v in Video, select: max(v.updated_at))
  def get_most_recent_inserted_at, do: Repo.one(from v in Video, select: max(v.inserted_at))
  def video_has_vmafs?(%Video{id: id}), do: Repo.exists?(from v in Vmaf, where: v.video_id == ^id)

  # Consolidated shared logic for video deletion
  defp delete_videos_by_ids(video_ids) do
    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id in ^video_ids) |> Repo.delete_all()
      from(v in Video, where: v.id in ^video_ids) |> Repo.delete_all()
    end)
  end

  def delete_videos_with_path(path) do
    video_ids = from(v in Video, where: ilike(v.path, ^path), select: v.id) |> Repo.all()
    delete_videos_by_ids(video_ids)
  end

  def delete_videos_with_nonexistent_paths do
    video_ids =
      from(v in Video, select: %{id: v.id, path: v.path})
      |> Repo.all()
      |> Enum.filter(fn %{path: path} -> !File.exists?(path) end)
      |> Enum.map(& &1.id)

    delete_videos_by_ids(video_ids)
  end

  # --- Library-related functions ---
  def list_libraries do
    Repo.all(from(l in Library))
  end

  def get_library!(id) do
    Repo.get!(Library, id)
  end

  def create_library(attrs \\ %{}) do
    %Library{} |> Library.changeset(attrs) |> Repo.insert()
  end

  def update_library(%Library{} = l, attrs), do: l |> Library.changeset(attrs) |> Repo.update()
  def delete_library(%Library{} = l), do: Repo.delete(l)
  def change_library(%Library{} = l, attrs \\ %{}), do: Library.changeset(l, attrs)
  # --- Vmaf-related functions ---
  def list_vmafs, do: Repo.all(Vmaf)
  def get_vmaf!(id), do: Repo.get!(Vmaf, id) |> Repo.preload(:video)
  def create_vmaf(attrs \\ %{}), do: %Vmaf{} |> Vmaf.changeset(attrs) |> Repo.insert()

  def upsert_vmaf(attrs) do
    result =
      %Vmaf{}
      |> Vmaf.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :video_id, :inserted_at]},
        conflict_target: [:crf, :video_id]
      )

    case result do
      {:ok, vmaf} ->
        Reencodarr.Telemetry.emit_vmaf_upserted(vmaf)

      _ ->
        :ok
    end

    result
  end

  def update_vmaf(%Vmaf{} = vmaf, attrs), do: vmaf |> Vmaf.changeset(attrs) |> Repo.update()
  def delete_vmaf(%Vmaf{} = vmaf), do: Repo.delete(vmaf)
  def change_vmaf(%Vmaf{} = vmaf, attrs \\ %{}), do: Vmaf.changeset(vmaf, attrs)

  def chosen_vmaf_exists?(%{id: id}),
    do: Repo.exists?(from v in Vmaf, where: v.video_id == ^id and v.chosen == true)

  # Consolidated shared logic for chosen VMAF queries
  defp query_chosen_vmafs do
    from v in Vmaf,
      join: vid in assoc(v, :video),
      where: v.chosen == true and vid.reencoded == false and vid.failed == false,
      preload: [:video],
      order_by: [asc: v.percent, asc: v.time]
  end

  # Function to list all chosen VMAFs
  def list_chosen_vmafs do
    Repo.all(query_chosen_vmafs())
  end

  # Function to get the chosen VMAF for a specific video
  def get_chosen_vmaf_for_video(%Video{id: video_id}) do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where:
          v.chosen == true and v.video_id == ^video_id and vid.reencoded == false and
            vid.failed == false,
        preload: [:video],
        order_by: [asc: v.percent, asc: v.time]
    )
  end

  # --- Stats and helpers ---
  def fetch_stats do
    case Repo.transaction(fn -> Repo.one(aggregated_stats_query()) end) do
      {:ok, stats} ->
        build_stats(stats)

      {:error, _} ->
        Logger.error("Failed to fetch stats")
        build_empty_stats()
    end
  end

  # Build full stats struct on successful DB query
  defp build_stats(stats) do
    next_crf_search = get_next_crf_search(5)
    videos_by_estimated_percent = list_videos_by_estimated_percent(5)
    next_analyzer = get_next_for_analysis(5)
    manual_items = manual_analyzer_items()
    combined_analyzer = manual_items ++ next_analyzer
    next_encoding = get_next_for_encoding()
    next_encoding_by_time = get_next_for_encoding_by_time()

    %Reencodarr.Statistics.Stats{
      avg_vmaf_percentage: stats.avg_vmaf_percentage,
      chosen_vmafs_count: stats.chosen_vmafs_count,
      lowest_vmaf_percent: next_encoding && next_encoding.percent,
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
        analyzer: stats.analyzer_count + length(manual_items)
      },
      next_crf_search: next_crf_search,
      videos_by_estimated_percent: videos_by_estimated_percent,
      next_analyzer: combined_analyzer
    }
  end

  # Manual analyzer queue items, skipping in test env and rescuing failures
  defp manual_analyzer_items do
    case Application.get_env(:reencodarr, :env) do
      :test ->
        []

      _ ->
        try do
          Producer.get_manual_queue()
        rescue
          _ -> []
        end
    end
  end

  # Build minimal stats struct when DB query fails
  defp build_empty_stats do
    %Reencodarr.Statistics.Stats{
      most_recent_video_update: most_recent_video_update() || nil,
      most_recent_inserted_video: get_most_recent_inserted_at() || nil
    }
  end

  defp aggregated_stats_query do
    from v in Video,
      where: v.failed == false,
      left_join: m_all in Vmaf,
      on: m_all.video_id == v.id,
      select: %{
        not_reencoded: fragment("COUNT(*) FILTER (WHERE ? = false)", v.reencoded),
        reencoded: fragment("COUNT(*) FILTER (WHERE ? = true)", v.reencoded),
        total_videos: count(v.id),
        avg_vmaf_percentage: fragment("ROUND(AVG(?)::numeric, 2)", m_all.percent),
        total_vmafs: count(m_all.id),
        chosen_vmafs_count: fragment("COUNT(*) FILTER (WHERE ? = true)", m_all.chosen),
        encodes_count:
          fragment("COUNT(*) FILTER (WHERE ? = false AND ? = true)", v.reencoded, m_all.chosen),
        queued_crf_searches_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IS NULL AND ? = false AND ? = false)",
            m_all.id,
            v.reencoded,
            v.failed
          ),
        analyzer_count:
          fragment("COUNT(*) FILTER (WHERE ? = 0 AND ? = false)", v.bitrate, v.failed),
        most_recent_video_update: max(v.updated_at),
        most_recent_inserted_video: max(v.inserted_at)
      }
  end

  def get_next_for_encoding_by_time,
    do:
      Repo.one(
        from v in Vmaf,
          join: vid in assoc(v, :video),
          where: v.chosen == true and vid.reencoded == false and vid.failed == false,
          order_by: [asc: v.time],
          limit: 1,
          preload: [:video]
      )

  def mark_vmaf_as_chosen(video_id, crf) do
    crf_float = parse_crf(crf)

    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id == ^video_id, update: [set: [chosen: false]])
      |> Repo.update_all([])

      from(v in Vmaf,
        where: v.video_id == ^video_id and v.crf == ^crf_float,
        update: [set: [chosen: true]]
      )
      |> Repo.update_all([])
    end)
  end

  defp parse_crf(crf) do
    case(Float.parse(crf)) do
      {value, _} -> value
      :error -> raise ArgumentError, "Invalid CRF value: #{crf}"
    end
  end

  def queued_crf_searches_query,
    do:
      from(v in Video,
        left_join: vmafs in assoc(v, :vmafs),
        where: is_nil(vmafs.id) and not v.reencoded and v.failed == false,
        select: v
      )

  def get_video(id) do
    Repo.get(Video, id)
  end

  def delete_unchosen_vmafs do
    Repo.transaction(fn ->
      # Get video_ids that have vmafs but none are chosen
      video_ids_with_no_chosen_vmafs =
        from(v in Vmaf,
          group_by: v.video_id,
          having: fragment("COUNT(*) FILTER (WHERE ? = true) = 0", v.chosen),
          select: v.video_id
        )
        |> Repo.all()

      # Delete all vmafs for those video_ids
      from(v in Vmaf, where: v.video_id in ^video_ids_with_no_chosen_vmafs)
      |> Repo.delete_all()
    end)
  end
end
