defmodule Reencodarr.Media do
  import Ecto.Query, warn: false
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
          # Alternate by library_id, then by quality within each library
          fragment(
            "? % (SELECT COUNT(DISTINCT library_id) FROM videos WHERE library_id IS NOT NULL)",
            vid.library_id
          ),
          fragment("? DESC NULLS LAST", v.savings),
          asc: v.percent,
          asc: v.time
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

  def encoding_queue_count do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.reencoded == false and vid.failed == false,
        select: count(v.id)
    )
  end

  def create_video(attrs \\ %{}), do: %Video{} |> Video.changeset(attrs) |> Repo.insert()

  def upsert_video(attrs) do
    attrs = ensure_library_id(attrs)
    path = get_path_from_attrs(attrs)

    # Extract the values we care about for comparison
    new_values = extract_comparison_values(attrs)
    being_marked_reencoded = get_attr_value(attrs, :reencoded) == true

    result =
      Repo.transaction(fn ->
        # Check if video exists and if any tracked properties are changing
        # Don't delete VMAFs if the video is being marked as reencoded
        existing_video = get_existing_video_for_comparison(path)

        if not being_marked_reencoded and should_delete_vmafs?(existing_video, new_values) do
          from(v in Vmaf, where: v.video_id == ^existing_video.id) |> Repo.delete_all()
        end

        attrs
        |> Video.changeset()
        |> Repo.insert(
          on_conflict: {:replace_all_except, [:id, :inserted_at, :reencoded, :failed]},
          conflict_target: :path
        )
      end)

    case result do
      {:ok, {:ok, video}} ->
        Reencodarr.Telemetry.emit_video_upserted(video)
        {:ok, video}

      {:ok, error} ->
        error

      {:error, _} = error ->
        error
    end
  end

  # Helper functions for cleaner attribute access
  defp get_path_from_attrs(attrs), do: Map.get(attrs, :path) || Map.get(attrs, "path")

  defp extract_comparison_values(attrs) do
    %{
      size: get_attr_value(attrs, :size),
      bitrate: get_attr_value(attrs, :bitrate),
      duration: get_attr_value(attrs, :duration),
      video_codecs: get_attr_value(attrs, :video_codecs),
      audio_codecs: get_attr_value(attrs, :audio_codecs)
    }
  end

  defp get_attr_value(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp get_existing_video_for_comparison(path) do
    Repo.one(
      from v in Video,
        where: v.path == ^path and v.reencoded == false and v.failed == false,
        select: %{
          id: v.id,
          size: v.size,
          bitrate: v.bitrate,
          duration: v.duration,
          video_codecs: v.video_codecs,
          audio_codecs: v.audio_codecs
        }
    )
  end

  defp should_delete_vmafs?(nil, _new_values), do: false

  defp should_delete_vmafs?(existing, new_values) do
    # Only check fields that have non-nil values in the new attributes
    # This avoids false positives when a field isn't being updated
    [
      {new_values.size, existing.size},
      {new_values.bitrate, existing.bitrate},
      {new_values.duration, existing.duration},
      {new_values.video_codecs, existing.video_codecs},
      {new_values.audio_codecs, existing.audio_codecs}
    ]
    |> Enum.any?(fn {new_val, old_val} ->
      not is_nil(new_val) and new_val != old_val
    end)
  end

  defp ensure_library_id(%{library_id: nil} = attrs),
    do: Map.put(attrs, :library_id, find_library_id(attrs[:path]))

  defp ensure_library_id(%{"library_id" => nil} = attrs),
    do: Map.put(attrs, "library_id", find_library_id(attrs["path"]))

  defp ensure_library_id(%{library_id: _} = attrs), do: attrs

  defp ensure_library_id(%{"library_id" => _} = attrs), do: attrs

  defp ensure_library_id(attrs) do
    path = Map.get(attrs, :path) || Map.get(attrs, "path")
    # Determine if this is an atom-keyed or string-keyed map and use consistent keys
    if Map.has_key?(attrs, :path) do
      Map.put(attrs, :library_id, find_library_id(path))
    else
      Map.put(attrs, "library_id", find_library_id(path))
    end
  end

  defp find_library_id(path) when is_binary(path) do
    # Find the library with the longest matching path (most specific)
    # Video path should start with library path
    from(l in Library,
      where: like(^path, fragment("concat(?, '%')", l.path)),
      order_by: [desc: fragment("length(?)", l.path)],
      select: l.id,
      limit: 1
    )
    |> Repo.one()
  end

  defp find_library_id(_), do: nil

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
    # Calculate savings if not provided but percent and video are available
    attrs_with_savings = maybe_calculate_savings(attrs)

    result =
      %Vmaf{}
      |> Vmaf.changeset(attrs_with_savings)
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

  # Calculate savings if not already provided and we have the necessary data
  defp maybe_calculate_savings(attrs) do
    case {Map.get(attrs, "savings"), Map.get(attrs, "percent"), Map.get(attrs, "video_id")} do
      {nil, percent, video_id} when not is_nil(percent) and not is_nil(video_id) ->
        case get_video(video_id) do
          %Video{size: size} when not is_nil(size) ->
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
    case Float.parse(percent) do
      {percent_float, _} -> calculate_vmaf_savings(percent_float, video_size)
      :error -> nil
    end
  end

  defp calculate_vmaf_savings(percent, video_size)
       when is_number(percent) and is_number(video_size) do
    if percent > 0 and percent <= 100 do
      # Savings = (100 - percent) / 100 * original_size
      round((100 - percent) / 100 * video_size)
    else
      nil
    end
  end

  defp calculate_vmaf_savings(_, _), do: nil

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

  # Manual analyzer queue items from QueueManager
  defp manual_analyzer_items do
    Reencodarr.Analyzer.QueueManager.get_queue()
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
          order_by: [fragment("? DESC NULLS LAST", v.savings), asc: v.time],
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

  # --- Bulk operations ---

  @doc """
  Reset all videos for reanalysis by clearing their bitrate.
  This is much more efficient than calling Analyzer.reanalyze_video/1 for each video.
  Videos will be automatically picked up by the analyzer when there's demand.
  VMAFs will be deleted automatically when videos are re-analyzed and their properties change.
  """
  def reset_all_videos_for_reanalysis do
    from(v in Video,
      where: v.reencoded == false and v.failed == false,
      update: [set: [bitrate: 0]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Reset videos for reanalysis in batches to avoid overwhelming the Broadway queue.
  VMAFs will be deleted automatically when videos are re-analyzed and their properties change.
  """
  def reset_videos_for_reanalysis_batched(batch_size \\ 1000) do
    videos_to_reset =
      from(v in Video,
        where: v.reencoded == false and v.failed == false,
        select: %{id: v.id}
      )
      |> Repo.all()

    total_videos = length(videos_to_reset)
    Logger.info("Resetting #{total_videos} videos for reanalysis in batches of #{batch_size}")

    videos_to_reset
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, index} ->
      Logger.info("Processing batch #{index + 1}/#{div(total_videos, batch_size) + 1}")

      # Reset bitrate for this batch
      video_ids = Enum.map(batch, & &1.id)

      from(v in Video, where: v.id in ^video_ids, update: [set: [bitrate: 0]])
      |> Repo.update_all([])

      # Small delay to prevent overwhelming the system
      Process.sleep(100)
    end)

    Logger.info("Completed resetting videos for reanalysis")
  end

  @doc """
  Reset all failed videos to not failed in a single bulk operation.
  """
  def reset_failed_videos do
    from(v in Video, where: v.failed == true, update: [set: [failed: false]])
    |> Repo.update_all([])
  end

  # --- Debug helpers ---

  @doc """
  Debug function to check the analyzer state and queue status.
  """
  def debug_analyzer_status do
    %{
      analyzer_running: Reencodarr.Analyzer.running?(),
      videos_needing_analysis: get_next_for_analysis(5),
      manual_queue: manual_analyzer_items(),
      total_analyzer_queue_count:
        length(get_next_for_analysis(100)) + length(manual_analyzer_items())
    }
  end

  @doc """
  Force trigger analysis of a specific video for debugging.
  """
  def debug_force_analyze_video(video_path) when is_binary(video_path) do
    case get_video_by_path(video_path) do
      %{path: path, service_id: service_id, service_type: service_type} = video ->
        Logger.info("🐛 Force analyzing video: #{path}")

        # Try both approaches
        result1 =
          Reencodarr.Analyzer.process_path(%{
            path: path,
            service_id: service_id,
            service_type: service_type,
            force_reanalyze: true
          })

        result2 = Reencodarr.Analyzer.reanalyze_video(video.id)

        %{
          video: video,
          process_path_result: result1,
          reanalyze_video_result: result2,
          broadway_running: Reencodarr.Analyzer.running?()
        }

      nil ->
        {:error, "Video not found at path: #{video_path}"}
    end
  end

  @doc """
  Debug function to show how the encoding queue alternates between libraries.
  """
  def debug_encoding_queue_libraries(limit \\ 10) do
    videos = query_videos_by_criteria(limit)

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
end
