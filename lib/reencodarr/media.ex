defmodule Reencodarr.Media do
  import Ecto.Query, warn: false
  alias Reencodarr.Repo
  alias Reencodarr.Media.{Video, Library, Vmaf}
  require Logger

  @default_stats %Reencodarr.Statistics.Stats{
    avg_vmaf_percentage: 0,
    chosen_vmafs_count: 0,
    lowest_vmaf_by_time: %Vmaf{},
    lowest_vmaf: %Vmaf{},
    not_reencoded: 0,
    reencoded: 0,
    total_videos: 0,
    total_vmafs: 0,
    most_recent_video_update: nil,
    most_recent_inserted_video: nil,
    queue_length: %{encodes: 0, crf_searches: 0}
  }

  # --- Video-related functions ---
  def list_videos, do: Repo.all(from v in Video, order_by: [desc: v.updated_at])
  def get_video!(id), do: Repo.get!(Video, id)
  def get_video_by_path(path), do: Repo.one(from v in Video, where: v.path == ^path)
  def video_exists?(path), do: Repo.exists?(from v in Video, where: v.path == ^path)

  def find_videos_by_path_wildcard(pattern),
    do: Repo.all(from v in Video, where: like(v.path, ^pattern))

  def get_next_crf_search(limit \\ 10),
    do:
      Repo.all(
        from v in Video,
          left_join: m in Vmaf,
          on: m.video_id == v.id,
          where:
            is_nil(m.id) and v.reencoded == false and v.failed == false and
              not fragment(
                "EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) = LOWER(?))",
                v.audio_codecs,
                "opus"
              ) and
              not fragment(
                "EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) = LOWER(?))",
                v.video_codecs,
                "av1"
              ),
          order_by: [desc: v.size, desc: v.bitrate, asc: v.updated_at],
          limit: ^limit,
          select: v
      )

  defp base_query_for_videos do
    from v in Vmaf,
      join: vid in assoc(v, :video),
      where: v.chosen == true and vid.reencoded == false and vid.failed == false,
      order_by: [asc: v.percent, asc: v.time],
      preload: [:video]
  end

  def list_videos_by_estimated_percent(limit \\ 10) do
    Repo.all(base_query_for_videos() |> limit(^limit))
    |> Enum.map(fn vmaf ->
      video_path = vmaf.video.path
      {List.last(String.split(video_path, "/")), vmaf.percent}
    end)
  end

  def get_next_for_encoding do
    Repo.one(base_query_for_videos() |> limit(1))
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
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "media_events", {:video_upserted, video})

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

  def delete_videos_with_path(path) do
    video_ids = from(v in Video, where: ilike(v.path, ^path), select: v.id) |> Repo.all()

    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id in ^video_ids) |> Repo.delete_all()
      from(v in Video, where: v.id in ^video_ids) |> Repo.delete_all()
    end)
  end

  def delete_videos_with_nonexistent_paths do
    video_ids =
      from(v in Video, select: %{id: v.id, path: v.path})
      |> Repo.all()
      |> Enum.filter(fn %{path: path} -> !File.exists?(path) end)
      |> Enum.map(& &1.id)

    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id in ^video_ids) |> Repo.delete_all()
      from(v in Video, where: v.id in ^video_ids) |> Repo.delete_all()
    end)
  end

  # --- Library-related functions ---
  def list_libraries, do: Repo.all(Library)
  def get_library!(id), do: Repo.get!(Library, id)
  def create_library(attrs \\ %{}), do: %Library{} |> Library.changeset(attrs) |> Repo.insert()
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
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "media_events", {:vmaf_upserted, vmaf})

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

  def list_chosen_vmafs,
    do:
      Repo.all(
        from v in Vmaf,
          join: vid in assoc(v, :video),
          where: v.chosen == true and vid.reencoded == false and vid.failed == false,
          order_by: [asc: v.percent, asc: v.time],
          preload: [:video]
      )

  def get_chosen_vmaf_for_video(%Video{id: id}),
    do: Repo.one(from v in Vmaf, where: v.video_id == ^id and v.chosen == true, preload: [:video])

  # --- Stats and helpers ---
  def fetch_stats do
    case Repo.transaction(fn -> Repo.one(aggregated_stats_query()) end) do
      {:ok, stats} ->
        %Reencodarr.Statistics.Stats{
          avg_vmaf_percentage: stats.avg_vmaf_percentage,
          chosen_vmafs_count: stats.chosen_vmafs_count,
          lowest_vmaf_by_time: get_next_for_encoding_by_time() || %Vmaf{},
          lowest_vmaf: get_next_for_encoding() || %Vmaf{},
          not_reencoded: stats.not_reencoded,
          reencoded: stats.reencoded,
          total_videos: stats.total_videos,
          total_vmafs: stats.total_vmafs,
          most_recent_video_update: stats.most_recent_video_update,
          most_recent_inserted_video: stats.most_recent_inserted_video,
          queue_length: %{
            encodes: stats.encodes_count,
            crf_searches: stats.queued_crf_searches_count
          }
        }

      {:error, _} ->
        Logger.error("Failed to fetch stats")

        %{
          @default_stats
          | most_recent_video_update: most_recent_video_update() || nil,
            most_recent_inserted_video: get_most_recent_inserted_at() || nil
        }
    end
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
end
