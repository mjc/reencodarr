defmodule Reencodarr.Media do
  import Ecto.Query, warn: false
  alias Reencodarr.Analyzer.QueueManager
  alias Reencodarr.Media.{Library, Video, VideoFailure, VideoValidator, Vmaf}
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

  def get_videos_for_crf_search(limit \\ 10) do
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

  def get_videos_needing_analysis(limit \\ 10) do
    # Get videos that need analysis (bitrate is null)
    Repo.all(
      from v in Video,
        where: is_nil(v.bitrate) and v.failed == false,
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
  end

  # Query for videos ready for encoding (chosen VMAFs with valid videos)
  defp query_videos_ready_for_encoding(limit) do
    # Use a more efficient approach: fetch videos by service type with 5:1 Sonarr:Radarr ratio
    sonarr_videos = get_videos_by_service_type("sonarr", calculate_sonarr_limit(limit))
    radarr_videos = get_videos_by_service_type("radarr", calculate_radarr_limit(limit))

    # Alternate with 5:1 ratio (5 Sonarr for every 1 Radarr)
    alternate_by_service_type(sonarr_videos, radarr_videos, limit)
  end

  # Calculate how many Sonarr videos we need (roughly 5/6 of total)
  defp calculate_sonarr_limit(total_limit) do
    # +2 buffer for safety
    max(1, round(total_limit * 9 / 10) + 2)
  end

  # Calculate how many Radarr videos we need (roughly 1/6 of total)
  defp calculate_radarr_limit(total_limit) do
    # +2 buffer for safety
    max(1, round(total_limit / 10) + 2)
  end

  # Get videos for a specific service type, alternating between libraries within that service
  defp get_videos_by_service_type(service_type, limit) do
    library_ids =
      get_active_library_ids_for_service(service_type)
      # Filter out any nil values for safety
      |> Enum.reject(&is_nil/1)

    case library_ids do
      [] ->
        []

      _ ->
        videos_per_library = max(1, div(limit, length(library_ids)) + 1)

        # Fetch top videos from each library for this service type in parallel
        videos_by_library =
          library_ids
          |> Task.async_stream(
            fn library_id ->
              videos =
                Repo.all(
                  from v in Vmaf,
                    join: vid in assoc(v, :video),
                    where:
                      v.chosen == true and vid.reencoded == false and vid.failed == false and
                        vid.library_id == ^library_id and vid.service_type == ^service_type,
                    order_by: [
                      fragment("? DESC NULLS LAST", v.savings),
                      asc: v.percent,
                      asc: v.time
                    ],
                    limit: ^videos_per_library,
                    preload: [:video]
                )

              {library_id, videos}
            end,
            max_concurrency: System.schedulers_online()
          )
          |> Enum.map(fn {:ok, result} -> result end)
          |> Enum.into(%{})

        # Alternate between libraries within this service type
        alternate_libraries(videos_by_library, library_ids, limit)
    end
  end

  # Get library IDs that have videos for a specific service type
  defp get_active_library_ids_for_service(service_type) do
    Repo.all(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where:
          v.chosen == true and vid.reencoded == false and vid.failed == false and
            vid.service_type == ^service_type and not is_nil(vid.library_id),
        distinct: vid.library_id,
        select: vid.library_id
    )
  end

  # Alternate between Sonarr and Radarr with 5:1 ratio
  defp alternate_by_service_type(sonarr_videos, radarr_videos, limit) do
    # Create a pattern: [S, S, S, S, S, R, S, S, S, S, S, R, ...]
    # where S = Sonarr, R = Radarr
    result = []
    sonarr_index = 0
    radarr_index = 0

    0..(limit - 1)
    |> Enum.reduce({result, sonarr_index, radarr_index}, fn index, {acc, s_idx, r_idx} ->
      # Every 6th position (0-indexed: 5, 11, 17, ...) gets a Radarr video
      if rem(index, 6) == 5 do
        add_radarr_video(radarr_videos, r_idx, acc, s_idx)
      else
        add_sonarr_video(sonarr_videos, s_idx, acc, r_idx)
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp add_radarr_video(radarr_videos, r_idx, acc, s_idx) do
    case Enum.at(radarr_videos, r_idx) do
      nil -> {acc, s_idx, r_idx}
      video -> {[video | acc], s_idx, r_idx + 1}
    end
  end

  defp add_sonarr_video(sonarr_videos, s_idx, acc, r_idx) do
    case Enum.at(sonarr_videos, s_idx) do
      nil -> {acc, s_idx, r_idx}
      video -> {[video | acc], s_idx + 1, r_idx}
    end
  end

  # Efficient alternation using indexed access
  defp alternate_libraries(videos_by_library, library_ids, limit) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(limit)
    |> Stream.map(fn index ->
      library_index = rem(index, length(library_ids))
      library_id = Enum.at(library_ids, library_index)
      video_position = div(index, length(library_ids))

      videos_by_library[library_id] |> Enum.at(video_position)
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end

  def list_videos_by_estimated_percent(limit \\ 10) do
    query_videos_ready_for_encoding(limit)
  end

  def get_next_for_encoding(limit \\ 1) do
    case limit do
      1 -> query_videos_ready_for_encoding(1) |> List.first()
      _ -> query_videos_ready_for_encoding(limit)
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

  def create_video(attrs \\ %{}) do
    %Video{} |> Video.changeset(attrs) |> Repo.insert()
  end

  def upsert_video(attrs) do
    # Normalize all keys to strings to avoid mixed key issues with Ecto
    attrs = normalize_keys_to_strings(attrs)

    # Debug log to see what we're working with
    if Map.has_key?(attrs, :size) do
      Logger.warning(
        "❌ Still have atom keys after normalization: #{inspect(Map.keys(attrs) |> Enum.take(10))}"
      )
    end

    attrs = ensure_library_id(attrs)
    path = get_path_from_attrs(attrs)

    # Extract the values we care about for comparison using VideoValidator
    new_values = VideoValidator.extract_comparison_values(attrs)
    being_marked_reencoded = get_attr_value(attrs, "reencoded") == true

    result =
      Repo.transaction(fn ->
        # Check if video exists and if any tracked properties are changing
        # Don't delete VMAFs if the video is being marked as reencoded
        existing_video = get_video_metadata_for_comparison(path)

        if not being_marked_reencoded and
             VideoValidator.should_delete_vmafs?(existing_video, new_values) do
          from(v in Vmaf, where: v.video_id == ^existing_video.id) |> Repo.delete_all()
        end

        # Don't reset bitrate if no significant properties have changed and we have an existing analyzed bitrate
        # Use specialized logic for bitrate preservation during sync operations
        preserve_bitrate = VideoValidator.should_preserve_bitrate?(existing_video, new_values)

        {final_attrs, conflict_except} =
          if not being_marked_reencoded and preserve_bitrate do
            # Preserve existing bitrate by removing both bitrate and mediainfo to prevent override
            # Also exclude bitrate from being replaced in the on_conflict
            Logger.debug(
              "Preserving existing bitrate #{existing_video.bitrate} for path #{path} (same file, different metadata)"
            )

            cleaned_attrs =
              attrs
              |> Map.delete("bitrate")
              |> Map.delete("mediainfo")

            {cleaned_attrs, [:id, :inserted_at, :reencoded, :failed, :bitrate]}
          else
            if not is_nil(existing_video) do
              Logger.debug(
                "Allowing bitrate update for path #{path}: preserve_bitrate=#{inspect(preserve_bitrate)}"
              )
            end

            {attrs, [:id, :inserted_at, :reencoded, :failed]}
          end

        %Video{}
        |> Video.changeset(final_attrs)
        |> Repo.insert(
          on_conflict: {:replace_all_except, conflict_except},
          conflict_target: :path
        )
      end)

    case result do
      {:ok, {:ok, video}} ->
        Reencodarr.Telemetry.emit_video_upserted(video)
        {:ok, video}

      {:ok, error} ->
        log_upsert_failure(path, attrs, error)
        error

      {:error, _} = error ->
        log_upsert_failure(path, attrs, error)
        error
    end
  end

  # Helper functions for cleaner attribute access
  defp normalize_keys_to_strings(attrs) when is_map(attrs) do
    # Force conversion using for comprehension to ensure all keys become strings
    for {key, value} <- attrs, into: %{} do
      string_key =
        cond do
          is_atom(key) -> Atom.to_string(key)
          is_binary(key) -> key
          true -> to_string(key)
        end

      {string_key, value}
    end
  end

  defp log_upsert_failure(path, attrs, error) do
    # Check if file actually exists on filesystem
    file_exists = File.exists?(path)

    # Check if video already exists in database
    existing_video = get_video_by_path(path)

    # Find library for this path
    library_id = find_library_id(path)

    messages = []
    errors = []

    # Add diagnostics about initial state
    {messages, errors} =
      if file_exists do
        {["File exists on filesystem" | messages], errors}
      else
        {["File does not exist on filesystem" | messages],
         ["File does not exist on filesystem: #{path}" | errors]}
      end

    messages =
      case existing_video do
        nil -> ["No existing video found in database" | messages]
        %Video{id: id} -> ["Found existing video with ID: #{id}" | messages]
      end

    {messages, errors} =
      case library_id do
        nil ->
          {["No matching library found for path" | messages],
           ["No matching library found for path" | errors]}

        lib_id ->
          {["Found library ID: #{lib_id}" | messages], errors}
      end

    # Extract error details
    error_details =
      case error do
        {:error, %Ecto.Changeset{} = changeset} ->
          changeset_errors =
            changeset.errors
            |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

          changeset_errors

        {:error, reason} ->
          ["Error: #{inspect(reason)}"]

        other ->
          ["Unknown error: #{inspect(other)}"]
      end

    final_errors = error_details ++ errors

    # Log the comprehensive failure information
    failure_info = %{
      path: path,
      success: false,
      operation: "upsert_failed",
      video_id: nil,
      messages: Enum.reverse(messages),
      errors: Enum.reverse(final_errors),
      library_id: library_id,
      file_exists: file_exists,
      had_existing_video: !is_nil(existing_video),
      provided_attrs: Map.keys(attrs) |> Enum.sort()
    }

    Logger.warning("❌ Video upsert failed: #{path}")
    Logger.warning("   Failure details: #{inspect(failure_info, pretty: true)}")
  end

  defp get_path_from_attrs(attrs), do: Map.get(attrs, "path")

  defp get_attr_value(attrs, key) when is_binary(key) do
    Map.get(attrs, key)
  end

  defp get_video_metadata_for_comparison(path) do
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

  defp ensure_library_id(%{"library_id" => nil} = attrs),
    do: Map.put(attrs, "library_id", find_library_id(attrs["path"]))

  defp ensure_library_id(%{"library_id" => _} = attrs), do: attrs

  defp ensure_library_id(attrs) do
    path = Map.get(attrs, "path")
    library_id = find_library_id(path)
    Map.put(attrs, "library_id", library_id)
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

  def update_video(%Video{} = video, attrs) do
    video |> Video.changeset(attrs) |> Repo.update()
  end

  def delete_video(%Video{} = video), do: Repo.delete(video)

  def change_video(%Video{} = video, attrs \\ %{}) do
    Video.changeset(video, attrs)
  end

  def update_video_status(%Video{} = video, attrs) do
    video |> Video.changeset(attrs) |> Repo.update()
  end

  def mark_as_reencoded(%Video{} = video),
    do: update_video_status(video, %{"reencoded" => true, "failed" => false})

  def mark_as_failed(%Video{} = video), do: update_video_status(video, %{"failed" => true})

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
  Resolves all failures for a video (typically when re-processing succeeds).
  """
  def resolve_video_failures(video_id) do
    video_id
    |> VideoFailure.get_unresolved_failures_for_video()
    |> Enum.each(&VideoFailure.resolve_failure/1)
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
    video_ids = get_video_ids_with_missing_files()
    delete_videos_by_ids(video_ids)
  end

  defp get_video_ids_with_missing_files do
    from(v in Video, select: %{id: v.id, path: v.path})
    |> Repo.all()
    |> Enum.filter(&file_missing?/1)
    |> Enum.map(& &1.id)
  end

  defp file_missing?(%{path: path}), do: not File.exists?(path)

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

  def update_library(%Library{} = l, attrs) do
    l |> Library.changeset(attrs) |> Repo.update()
  end

  def delete_library(%Library{} = l), do: Repo.delete(l)

  def change_library(%Library{} = l, attrs \\ %{}) do
    Library.changeset(l, attrs)
  end

  # --- Vmaf-related functions ---
  def list_vmafs, do: Repo.all(Vmaf)
  def get_vmaf!(id), do: Repo.get!(Vmaf, id) |> Repo.preload(:video)

  def create_vmaf(attrs \\ %{}) do
    %Vmaf{} |> Vmaf.changeset(attrs) |> Repo.insert()
  end

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
       when is_number(percent) and is_number(video_size) and
              percent > 0 and percent <= 100 do
    # Savings = (100 - percent) / 100 * original_size
    round((100 - percent) / 100 * video_size)
  end

  defp calculate_vmaf_savings(_, _), do: nil

  def update_vmaf(%Vmaf{} = vmaf, attrs) do
    vmaf |> Vmaf.changeset(attrs) |> Repo.update()
  end

  def delete_vmaf(%Vmaf{} = vmaf), do: Repo.delete(vmaf)

  def change_vmaf(%Vmaf{} = vmaf, attrs \\ %{}) do
    Vmaf.changeset(vmaf, attrs)
  end

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
    next_items = fetch_next_items()
    queue_lengths = calculate_queue_lengths(stats, next_items.manual_items)

    %Reencodarr.Statistics.Stats{
      avg_vmaf_percentage: stats.avg_vmaf_percentage,
      chosen_vmafs_count: stats.chosen_vmafs_count,
      lowest_vmaf_percent: next_items.next_encoding && next_items.next_encoding.percent,
      lowest_vmaf_by_time_seconds:
        next_items.next_encoding_by_time && next_items.next_encoding_by_time.time,
      not_reencoded: stats.not_reencoded,
      reencoded: stats.reencoded,
      total_videos: stats.total_videos,
      total_vmafs: stats.total_vmafs,
      most_recent_video_update: stats.most_recent_video_update,
      most_recent_inserted_video: stats.most_recent_inserted_video,
      queue_length: queue_lengths,
      next_crf_search: next_items.next_crf_search,
      videos_by_estimated_percent: next_items.videos_by_estimated_percent,
      next_analyzer: next_items.combined_analyzer
    }
  end

  defp fetch_next_items do
    next_crf_search = get_videos_for_crf_search(5)
    videos_by_estimated_percent = list_videos_by_estimated_percent(5)
    next_analyzer = get_videos_needing_analysis(5)
    manual_items = get_manual_analyzer_items()
    combined_analyzer = manual_items ++ next_analyzer
    next_encoding = get_next_for_encoding()
    next_encoding_by_time = get_next_for_encoding_by_time()

    %{
      next_crf_search: next_crf_search,
      videos_by_estimated_percent: videos_by_estimated_percent,
      next_analyzer: next_analyzer,
      manual_items: manual_items,
      combined_analyzer: combined_analyzer,
      next_encoding: next_encoding,
      next_encoding_by_time: next_encoding_by_time
    }
  end

  defp calculate_queue_lengths(stats, manual_items) do
    %{
      encodes: stats.encodes_count,
      crf_searches: stats.queued_crf_searches_count,
      analyzer: stats.analyzer_count + length(manual_items)
    }
  end

  # Manual analyzer queue items from QueueManager
  defp get_manual_analyzer_items do
    QueueManager.get_queue()
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
          fragment("COUNT(*) FILTER (WHERE ? IS NULL AND ? = false)", v.bitrate, v.failed),
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
    case Float.parse(crf) do
      {value, _} -> value
      :error -> raise ArgumentError, "Invalid CRF value: #{crf}"
    end
  end

  def list_videos_awaiting_crf_search do
    from(v in Video,
      left_join: vmafs in assoc(v, :vmafs),
      where: is_nil(vmafs.id) and not v.reencoded and v.failed == false,
      select: v
    )
    |> Repo.all()
  end

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
      update: [set: [bitrate: nil]]
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

      # Reset bitrate for this batch (set to NULL so analyzer picks them up)
      video_ids = Enum.map(batch, & &1.id)

      from(v in Video, where: v.id in ^video_ids, update: [set: [bitrate: nil]])
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
      videos_needing_analysis: get_videos_needing_analysis(5),
      manual_queue: get_manual_analyzer_items(),
      total_analyzer_queue_count:
        length(get_videos_needing_analysis(100)) + length(get_manual_analyzer_items())
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
  Explains where a specific video path is located in the system and which queues it belongs to.

  Returns a detailed map with information about:
  - Database state (analyzed, has VMAF, ready for encoding, etc.)
  - Current queue memberships (analyzer, CRF searcher, encoder)
  - Processing status and next steps
  - Error states if any

  ## Examples

      iex> Reencodarr.Media.explain_path_location("/path/to/video.mkv")
      %{
        path: "/path/to/video.mkv",
        exists_in_db: true,
        database_state: %{
          analyzed: true,
          has_vmaf: true,
          ready_for_encoding: true,
          reencoded: false,
          failed: false
        },
        queue_memberships: %{
          analyzer_broadway: false,
          analyzer_manual: false,
          crf_searcher_broadway: false,
          crf_searcher_genserver: false,
          encoder_broadway: true,
          encoder_genserver: false
        },
        next_steps: ["ready for encoding"],
        details: %{
          video_id: 123,
          library_name: "Movies",
          bitrate: 5000,
          vmaf_count: 3,
          chosen_vmaf: %{crf: 23, percent: 95.2}
        }
      }
  """
  @spec explain_path_location(String.t()) :: %{
          path: String.t(),
          exists_in_db: boolean(),
          database_state: %{
            analyzed: boolean(),
            has_vmaf: boolean(),
            ready_for_encoding: boolean(),
            reencoded: boolean(),
            failed: boolean()
          },
          queue_memberships: %{
            analyzer_broadway: boolean(),
            analyzer_manual: boolean(),
            crf_searcher_broadway: boolean(),
            crf_searcher_genserver: boolean(),
            encoder_broadway: boolean(),
            encoder_genserver: boolean()
          },
          next_steps: [String.t()],
          details: map() | nil
        }
  def explain_path_location(path) when is_binary(path) do
    case get_video_by_path(path) do
      nil ->
        %{
          path: path,
          exists_in_db: false,
          database_state: %{
            analyzed: false,
            has_vmaf: false,
            ready_for_encoding: false,
            reencoded: false,
            failed: false
          },
          queue_memberships: %{
            analyzer_broadway: false,
            analyzer_manual: false,
            crf_searcher_broadway: false,
            crf_searcher_genserver: false,
            encoder_broadway: false,
            encoder_genserver: false
          },
          next_steps: ["not in database - needs to be added"],
          details: nil
        }

      video ->
        # Get associated VMAFs
        vmafs = Repo.all(from v in Vmaf, where: v.video_id == ^video.id, preload: [:video])
        chosen_vmaf = Enum.find(vmafs, & &1.chosen)

        # Determine database state
        analyzed = !is_nil(video.bitrate)
        has_vmaf = length(vmafs) > 0
        ready_for_encoding = !is_nil(chosen_vmaf) && !video.reencoded && !video.failed

        # Check queue memberships
        queue_memberships = %{
          analyzer_broadway: path_in_analyzer_broadway?(path),
          analyzer_manual: path_in_analyzer_manual?(path),
          crf_searcher_broadway: path_in_crf_searcher_broadway?(path),
          crf_searcher_genserver: path_in_crf_searcher_genserver?(path),
          encoder_broadway: path_in_encoder_broadway?(path),
          encoder_genserver: path_in_encoder_genserver?(path)
        }

        # Determine next steps
        next_steps =
          determine_next_steps(video, analyzed, has_vmaf, ready_for_encoding, chosen_vmaf)

        # Get library name
        library = video.library_id && Repo.get(Library, video.library_id)

        %{
          path: path,
          exists_in_db: true,
          database_state: %{
            analyzed: analyzed,
            has_vmaf: has_vmaf,
            ready_for_encoding: ready_for_encoding,
            reencoded: video.reencoded,
            failed: video.failed
          },
          queue_memberships: queue_memberships,
          next_steps: next_steps,
          details: %{
            video_id: video.id,
            library_name: library && library.name,
            bitrate: video.bitrate,
            vmaf_count: length(vmafs),
            chosen_vmaf: chosen_vmaf && %{crf: chosen_vmaf.crf, percent: chosen_vmaf.percent},
            video_codecs: video.video_codecs,
            audio_codecs: video.audio_codecs,
            size: video.size,
            inserted_at: video.inserted_at,
            updated_at: video.updated_at
          }
        }
    end
  end

  # Helper functions to check queue memberships
  defp path_in_analyzer_broadway?(_path) do
    # The analyzer Broadway producer manages its own queue internally
    # We can't easily check this without accessing its internal state
    # For now, return false as this would require more complex introspection
    false
  end

  defp path_in_analyzer_manual?(path) do
    # Check the QueueManager's manual queue
    manual_queue = QueueManager.get_queue()

    Enum.any?(manual_queue, fn item ->
      case item do
        %{path: item_path} -> String.downcase(item_path) == String.downcase(path)
        _ -> false
      end
    end)
  end

  defp path_in_crf_searcher_broadway?(_path) do
    # Similar to analyzer Broadway, internal state not easily accessible
    false
  end

  defp path_in_crf_searcher_genserver?(_path) do
    # Would need to inspect GenServer message queue, which is not practical
    false
  end

  defp path_in_encoder_broadway?(_path) do
    # Similar to other Broadway producers
    false
  end

  defp path_in_encoder_genserver?(_path) do
    # Would need to inspect GenServer message queue, which is not practical
    false
  end

  defp determine_next_steps(video, analyzed, has_vmaf, ready_for_encoding, chosen_vmaf) do
    determine_video_status(video, analyzed, has_vmaf, ready_for_encoding, chosen_vmaf)
  end

  defp determine_video_status(video, _analyzed, _has_vmaf, _ready_for_encoding, _chosen_vmaf)
       when video.failed do
    ["marked as failed - manual intervention needed"]
  end

  defp determine_video_status(video, _analyzed, _has_vmaf, _ready_for_encoding, _chosen_vmaf)
       when video.reencoded do
    ["already reencoded - processing complete"]
  end

  defp determine_video_status(_video, _analyzed, _has_vmaf, true, chosen_vmaf) do
    ["ready for encoding with CRF #{chosen_vmaf.crf}"]
  end

  defp determine_video_status(_video, _analyzed, true, _ready_for_encoding, nil) do
    ["has VMAF results but none chosen - needs manual selection"]
  end

  defp determine_video_status(video, true, false, _ready_for_encoding, _chosen_vmaf) do
    determine_analyzed_video_steps(video)
  end

  defp determine_video_status(_video, false, _has_vmaf, _ready_for_encoding, _chosen_vmaf) do
    ["needs analysis - should be in analyzer queue"]
  end

  defp determine_video_status(_video, _analyzed, _has_vmaf, _ready_for_encoding, _chosen_vmaf) do
    ["unknown state - check manually"]
  end

  defp determine_analyzed_video_steps(video) do
    cond do
      has_av1_codec?(video) ->
        ["already AV1 encoded - no CRF search needed"]

      has_opus_codec?(video) ->
        ["has Opus audio - skipped from CRF search queue"]

      true ->
        ["analyzed but needs CRF search"]
    end
  end

  defp has_av1_codec?(video) do
    Enum.any?(video.video_codecs || [], fn codec ->
      String.downcase(codec) |> String.contains?("av1")
    end)
  end

  defp has_opus_codec?(video) do
    Enum.any?(video.audio_codecs || [], fn codec ->
      String.downcase(codec) |> String.contains?("opus")
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
          errors: [String.t()]
        }
  def test_insert_path(path, additional_attrs \\ %{}) when is_binary(path) do
    Logger.info("🧪 Testing path insertion: #{path}")

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
    library_id = find_library_id(path)

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
      "reencoded" => false,
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

  defp add_file_existence_messages(file_exists, path, messages, errors) do
    if file_exists do
      {["File exists on filesystem" | messages], errors}
    else
      {["File does not exist on filesystem" | messages],
       ["File does not exist on filesystem: #{path}" | errors]}
    end
  end

  defp add_existing_video_messages(existing_video, messages) do
    case existing_video do
      nil -> ["No existing video found in database" | messages]
      %Video{id: id} -> ["Found existing video with ID: #{id}" | messages]
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
        operation = if diagnostics.existing_video, do: "upsert", else: "insert"

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
      |> Map.put(:had_existing_video, !is_nil(diagnostics.existing_video))
      |> Map.put(:messages, Enum.reverse(result.messages))
      |> Map.put(:errors, Enum.reverse(result.errors))

    Logger.info("🧪 Test result: #{if result.success, do: "SUCCESS", else: "FAILED"}")

    if result.success do
      Logger.info("   Video ID: #{result.video_id}, Operation: #{result.operation}")
    else
      Logger.warning("   Errors: #{Enum.join(result.errors, ", ")}")
    end

    final_result
  end
end
