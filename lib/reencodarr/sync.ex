defmodule Reencodarr.Sync do
  @moduledoc "Coordinates fetching items from Sonarr/Radarr and syncing them into the database."
  use GenServer
  require Logger
  import Ecto.Query
  alias Reencodarr.Analyzer.Broadway, as: AnalyzerBroadway
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.{Media, Repo, Services}

  alias Reencodarr.Media.{MediaInfoExtractor, VideoFileInfo, VideoUpsert}
  alias Reencodarr.Media.Video.MediaInfoConverter

  @default_batch_size 10
  @default_write_batch_size 100
  @default_fetch_timeout_ms 90_000
  @default_fetch_concurrency 2
  # Sync every 6 hours by default; override via :sync_interval_ms app env
  @default_sync_interval_ms :timer.hours(6)

  # Public API
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def sync_episodes, do: GenServer.cast(__MODULE__, :sync_episodes)
  def sync_movies, do: GenServer.cast(__MODULE__, :sync_movies)

  # GenServer Callbacks
  def init(state) do
    schedule_sync()
    {:ok, state}
  end

  def handle_cast(:refresh_and_rename_series, state) do
    Services.Sonarr.refresh_and_rename_all_series()
    {:noreply, state}
  end

  def handle_cast(action, state) when action in [:sync_episodes, :sync_movies] do
    sync_config = resolve_action(action)
    service_type = sync_config.service_type

    Events.broadcast_event(:sync_started, %{service_type: service_type})

    try do
      sync_items(sync_config)
    rescue
      e ->
        Logger.error("Sync #{service_type} crashed: #{Exception.message(e)}")
    catch
      kind, reason ->
        Logger.error("Sync #{service_type} failed (#{kind}): #{inspect(reason)}")
    end

    Events.broadcast_event(:sync_completed, %{service_type: service_type})

    # Trigger analyzer to process any videos that need analysis after sync completion
    AnalyzerBroadway.dispatch_available()

    {:noreply, state}
  end

  def handle_info(:periodic_sync, state) do
    Logger.info("Sync: running scheduled periodic sync")
    sync_episodes()
    sync_movies()
    schedule_sync()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private Functions
  defp resolve_action(:sync_episodes),
    do: %{
      get_items: &Services.get_shows/0,
      get_files: &Services.get_episode_files/1,
      service_type: :sonarr
    }

  defp resolve_action(:sync_movies),
    do: %{
      get_items: &Services.get_movies/0,
      get_files: &Services.get_movie_files/1,
      service_type: :radarr
    }

  defp sync_items(%{
         get_items: get_items,
         get_files: get_files,
         service_type: service_type
       }) do
    case get_items.() do
      {:ok, %Req.Response{body: items}} when is_list(items) ->
        process_items_in_batches(items, get_files, service_type)

      _ ->
        Logger.error("Sync error: unexpected response")
    end
  end

  defp process_items_in_batches(items, get_files, service_type) do
    total_items = length(items)
    library_mappings = preload_library_mappings()
    started_at = System.monotonic_time(:millisecond)

    summary =
      items
      |> Stream.chunk_every(sync_batch_size())
      |> Stream.with_index()
      |> Enum.reduce(%{batches: 0, items_processed: 0, files_seen: 0, files_written: 0}, fn batch,
                                                                                            acc ->
        stats = process_batch(batch, get_files, service_type, total_items, library_mappings)

        %{
          batches: acc.batches + 1,
          items_processed: acc.items_processed + stats.items_processed,
          files_seen: acc.files_seen + stats.files_seen,
          files_written: acc.files_written + stats.files_written
        }
      end)

    duration = System.monotonic_time(:millisecond) - started_at

    Logger.info(
      "Sync: #{service_type} completed #{summary.items_processed}/#{total_items} items " <>
        "across #{summary.batches} batches, saw #{summary.files_seen} files, " <>
        "wrote #{summary.files_written} files in #{duration}ms"
    )
  end

  defp process_batch({batch, batch_index}, get_files, service_type, total_items, library_mappings) do
    batch_start_time = System.monotonic_time(:millisecond)

    stats =
      Task.Supervisor.async_stream_nolink(
        Reencodarr.TaskSupervisor,
        batch,
        &fetch_item_files(&1, get_files),
        max_concurrency: sync_fetch_concurrency(),
        timeout: sync_fetch_timeout_ms(),
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{items_processed: 0, files_seen: 0, files_written: 0}, fn result, acc ->
        process_item_fetch_result(result, service_type, library_mappings, batch_index, acc)
      end)

    batch_duration = System.monotonic_time(:millisecond) - batch_start_time

    Logger.debug(
      "Sync: Batch #{batch_index} processed #{stats.items_processed} items, " <>
        "saw #{stats.files_seen} files, wrote #{stats.files_written} files in #{batch_duration}ms"
    )

    Events.broadcast_event(:sync_progress, %{
      progress: progress_percent(batch_index, sync_batch_size(), total_items),
      service_type: service_type
    })

    stats
  end

  defp process_item_fetch_result(
         {:ok, {:ok, item_id, files}},
         service_type,
         library_mappings,
         _batch_index,
         acc
       ) do
    files_written = write_item_files(files, service_type, library_mappings)

    Logger.debug(
      "Sync: Item #{inspect(item_id)} fetched #{length(files)} files, wrote #{files_written} files"
    )

    %{
      items_processed: acc.items_processed + 1,
      files_seen: acc.files_seen + length(files),
      files_written: acc.files_written + files_written
    }
  end

  defp process_item_fetch_result(
         {:ok, {:error, item_id, reason}},
         _service_type,
         _library_mappings,
         _batch_index,
         acc
       ) do
    Logger.warning("Sync: Failed to fetch files for item #{inspect(item_id)}: #{inspect(reason)}")
    %{acc | items_processed: acc.items_processed + 1}
  end

  defp process_item_fetch_result(
         {:exit, reason},
         _service_type,
         _library_mappings,
         batch_index,
         acc
       ) do
    Logger.warning("Sync: Task failed in batch #{batch_index}: #{inspect(reason)}")
    %{acc | items_processed: acc.items_processed + 1}
  end

  defp write_item_files([], _service_type, _library_mappings), do: 0

  defp write_item_files(files, service_type, library_mappings) do
    files
    |> Enum.chunk_every(sync_write_batch_size())
    |> Enum.reduce(0, fn chunk, written ->
      written + batch_upsert_videos(chunk, service_type, library_mappings)
    end)
  end

  defp sync_batch_size do
    Application.get_env(:reencodarr, :sync_batch_size, @default_batch_size)
  end

  defp sync_write_batch_size do
    Application.get_env(:reencodarr, :sync_write_batch_size) ||
      Application.get_env(:reencodarr, :sync_file_batch_size, @default_write_batch_size)
  end

  defp progress_percent(_batch_index, _batch_size, 0), do: 100

  defp progress_percent(batch_index, batch_size, total_count) do
    processed_count = min((batch_index + 1) * batch_size, total_count)
    div(processed_count * 100, total_count)
  end

  defp sync_fetch_timeout_ms do
    Application.get_env(:reencodarr, :sync_fetch_timeout_ms, @default_fetch_timeout_ms)
  end

  defp sync_fetch_concurrency do
    Application.get_env(:reencodarr, :sync_fetch_concurrency, @default_fetch_concurrency)
  end

  @doc """
  Batch upserts multiple videos with library mapping cache optimization.
  This function is exposed for testing performance optimizations.
  """
  def batch_upsert_videos(files, service_type) do
    library_mappings = preload_library_mappings()

    batch_upsert_videos(files, service_type, library_mappings)
    :ok
  end

  defp batch_upsert_videos(files, service_type, library_mappings) do
    file_refs = extract_file_refs(files)

    # Pre-filter: only look up rows for paths in this batch instead of loading the
    # full service library into memory on every sync batch.
    known_files = preload_known_files(service_type, file_refs)

    {new_or_changed, skipped} =
      Enum.split_with(files, fn file ->
        file_changed?(file, known_files)
      end)

    if skipped != [] do
      Logger.debug("Sync: Skipped #{length(skipped)} unchanged files")
    end

    video_attrs_list =
      new_or_changed
      |> Enum.map(&prepare_video_attrs(&1, service_type, library_mappings))
      |> Enum.reject(&is_nil/1)

    if video_attrs_list != [] do
      Logger.debug("Sync: Processing #{length(video_attrs_list)} changed videos in batch")
      perform_batch_transaction(video_attrs_list)
    else
      0
    end
  end

  defp preload_known_files(_service_type, []), do: MapSet.new()

  defp preload_known_files(service_type, file_refs) do
    paths =
      file_refs
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    Repo.all(
      from v in Media.Video,
        where: v.service_type == ^service_type and v.path in ^paths,
        select: {v.path, v.service_id}
    )
    |> MapSet.new()
  end

  defp file_changed?(file, known_files) do
    {path, file_id} = extract_path_and_id(file)
    path == nil or not MapSet.member?(known_files, {path, file_id})
  end

  defp extract_path_and_id(%{"path" => path, "id" => id}), do: {path, to_string(id)}
  defp extract_path_and_id(%VideoFileInfo{path: path, service_id: sid}), do: {path, sid}
  defp extract_path_and_id(_), do: {nil, nil}

  defp extract_file_refs(files) do
    files
    |> Enum.map(&extract_path_and_id/1)
    |> Enum.reject(fn {path, _id} -> is_nil(path) end)
  end

  defp perform_batch_transaction(video_attrs_list) do
    # Use the new batch upsert function which handles its own transaction
    results = Media.batch_upsert_videos(video_attrs_list)

    # Count successes and failures
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = length(results) - success_count

    if error_count > 0 do
      Logger.warning(
        "Sync: Batch completed with #{error_count} errors out of #{length(results)} videos"
      )
    else
      Logger.debug("Sync: Successfully processed #{success_count} videos")
    end

    success_count
  end

  defp preload_library_mappings do
    # Pre-fetch all libraries to avoid repeated queries
    # Sort by path length descending for proper longest-match-first behavior
    Repo.all(
      from l in Media.Library,
        select: %{id: l.id, path: l.path}
    )
    |> Enum.sort_by(&byte_size(&1.path), :desc)
  end

  defp find_library_id_from_cache(path, library_mappings) do
    Enum.find_value(library_mappings, fn lib ->
      if String.starts_with?(path, lib.path), do: lib.id
    end)
  end

  defp prepare_video_attrs(file, service_type, library_mappings) do
    # Handle different file formats
    case file do
      %{"path" => path, "size" => size} = raw_file ->
        library_id = find_library_id_from_cache(path, library_mappings)

        base_attrs = %{
          "path" => path,
          "size" => size,
          "service_id" => to_string(raw_file["id"]),
          "service_type" => to_string(service_type),
          "library_id" => library_id,
          "dateAdded" => raw_file["dateAdded"],
          "content_year" => extract_year_from_raw_file(raw_file, service_type)
        }

        # Add mediainfo if present
        if raw_file["mediaInfo"] do
          mediainfo = MediaInfoConverter.from_service_file(raw_file, service_type)

          Map.merge(base_attrs, %{
            "mediainfo" => mediainfo,
            "bitrate" => raw_file["overallBitrate"] || 0
          })
        else
          Map.put(base_attrs, "bitrate", 0)
        end

      %VideoFileInfo{} = info ->
        library_id = find_library_id_from_cache(info.path, library_mappings)
        mediainfo = MediaInfoConverter.from_video_file_info(info)

        %{
          "path" => info.path,
          "size" => info.size,
          "service_id" => info.service_id,
          "service_type" => to_string(service_type),
          "library_id" => library_id,
          "mediainfo" => mediainfo,
          "bitrate" => info.bitrate,
          "dateAdded" => info.date_added,
          "content_year" => info.content_year
        }

      _ ->
        Logger.warning("Unknown file format: #{inspect(file)}")
        nil
    end
  end

  defp fetch_item_files(item, get_files) do
    id = item_id(item)

    case get_files.(id) do
      {:ok, %Req.Response{body: files}} when is_list(files) ->
        {:ok, id, files}

      response ->
        {:error, id, response}
    end
  rescue
    error ->
      {:error, item_id(item), Exception.message(error)}
  catch
    kind, reason ->
      {:error, item_id(item), {kind, reason}}
  end

  defp item_id(%{"id" => id}), do: id
  defp item_id(%{id: id}), do: id
  defp item_id(_), do: nil

  # Keep these functions for individual file processing (used by webhooks)
  def upsert_video_from_file(%VideoFileInfo{size: nil} = file, service_type) do
    Logger.warning("File size is missing: #{inspect(file)}")
    process_single_video_file(file, service_type)
  end

  def upsert_video_from_file(%VideoFileInfo{} = file, service_type) do
    process_single_video_file(file, service_type)
  end

  def upsert_video_from_file(
        %{"path" => _path, "size" => _size} = file,
        service_type
      ) do
    info = build_video_file_info(file, Map.get(file, "mediaInfo"), service_type)
    upsert_video_from_file(info, service_type)
  end

  defp process_single_video_file(%VideoFileInfo{} = info, _service_type) do
    # Check if video exists and file size hasn't changed
    existing_video = Media.get_video_by_path(info.path)

    # VideoUpsert will automatically set state to needs_analysis for zero bitrate
    {:ok, handle_video_upsert(existing_video, info)}
  end

  defp handle_video_upsert({:ok, video}, info) do
    if should_preserve_file_metadata?(video, info) do
      update_api_metadata_only(video, info)
    else
      upsert_full_video_data(info)
    end
  end

  defp handle_video_upsert({:error, :not_found}, info) do
    upsert_full_video_data(info)
  end

  defp should_preserve_file_metadata?(existing_video, info) do
    existing_video.size == info.size && info.bitrate != 0
  end

  defp update_api_metadata_only(existing_video, info) do
    # File size unchanged AND bitrate is not 0 - only update API-sourced metadata
    api_only_attrs = %{
      "service_id" => info.service_id,
      "service_type" => to_string(info.service_type),
      "content_year" => info.content_year,
      "dateAdded" => info.date_added
    }

    Media.update_video(existing_video, api_only_attrs)
  end

  defp upsert_full_video_data(info) do
    # File size changed, new video, OR bitrate is 0 (needs re-analysis) - analyze everything
    # Convert VideoFileInfo to MediaInfo format for database storage
    mediainfo = MediaInfoConverter.from_video_file_info(info)

    # Extract video parameters including required fields like max_audio_channels and atmos
    case MediaInfoExtractor.extract_video_params(mediainfo, info.path) do
      video_params when is_map(video_params) ->
        # Convert atom keys to string keys for consistency
        string_video_params = Map.new(video_params, fn {k, v} -> {to_string(k), v} end)

        VideoUpsert.upsert(
          Map.merge(
            %{
              "path" => info.path,
              "size" => info.size,
              "service_id" => info.service_id,
              "service_type" => to_string(info.service_type),
              "mediainfo" => mediainfo,
              "bitrate" => info.bitrate,
              "dateAdded" => info.date_added,
              "content_year" => info.content_year
            },
            string_video_params
          )
        )

      {:error, reason} ->
        Logger.warning("Could not extract video parameters for #{info.path}: #{reason}")

        # Fallback: upsert without extracted params, video will need analysis
        VideoUpsert.upsert(%{
          "path" => info.path,
          "size" => info.size,
          "service_id" => info.service_id,
          "service_type" => to_string(info.service_type),
          "mediainfo" => mediainfo,
          "dateAdded" => info.date_added,
          "content_year" => info.content_year
        })
    end
  end

  @doc """
  Process raw service file data directly using MediaInfo conversion.
  This bypasses the VideoFileInfo struct for simpler processing.
  """
  def upsert_video_from_service_file(file, service_type)
      when service_type in [:sonarr, :radarr] do
    # Convert directly to MediaInfo format
    mediainfo = MediaInfoConverter.from_service_file(file, service_type)

    # Store in database.
    # VideoUpsert will automatically set state to needs_analysis for missing bitrate.
    VideoUpsert.upsert(%{
      "path" => file["path"],
      "size" => file["size"],
      "service_id" => to_string(file["id"]),
      "service_type" => to_string(service_type),
      "mediainfo" => mediainfo,
      "bitrate" => file["overallBitrate"] || 0,
      "dateAdded" => file["dateAdded"]
    })
  end

  defp build_video_file_info(file, _media_info, service_type) do
    # Use the new converter
    MediaInfoConverter.video_file_info_from_file(file, service_type)
  end

  def refresh_operations(file_id, :sonarr) do
    with {:ok, %Req.Response{body: episode_file}} <- Services.Sonarr.get_episode_file(file_id),
         {:ok, series_id} <- validate_series_id(episode_file["seriesId"]),
         {:ok, _} <- Services.Sonarr.refresh_series_and_wait(series_id),
         {:ok, _} <- Services.Sonarr.rename_files(series_id) do
      {:ok, "Refresh and rename triggered"}
    end
  end

  def refresh_operations(file_id, :radarr) do
    with {:ok, %Req.Response{body: movie_file}} <- Services.Radarr.get_movie_file(file_id),
         {:ok, movie_id} <- validate_movie_id(movie_file["movieId"]),
         {:ok, _} <- Services.Radarr.refresh_movie_and_wait(movie_id),
         {:ok, _} <- Services.Radarr.rename_movie_files(movie_id) do
      {:ok, "Refresh and rename triggered for Radarr"}
    end
  end

  def refresh_and_rename_from_video(%{service_type: service_type, service_id: id})
      when service_type in [:sonarr, :radarr] and not is_nil(id) do
    with {:ok, int_id} <- coerce_to_integer(id) do
      refresh_operations(int_id, service_type)
    end
  end

  def refresh_and_rename_from_video(%{service_type: nil}),
    do: {:error, "No service type for video"}

  def refresh_and_rename_from_video(%{service_id: nil}),
    do: {:error, "No service_id for video"}

  defp coerce_to_integer(id) when is_integer(id), do: {:ok, id}

  defp coerce_to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> {:ok, int_id}
      _ -> {:error, "Invalid service_id: #{id}"}
    end
  end

  def rescan_and_rename_series(id), do: refresh_operations(id, :sonarr)

  # Helper function to validate series ID from episode file response
  defp validate_series_id(nil) do
    Logger.error("Series ID is null - episode file may be orphaned or invalid")
    {:error, "Series ID is null"}
  end

  defp validate_series_id(series_id) when is_integer(series_id) and series_id > 0 do
    {:ok, series_id}
  end

  defp validate_series_id(series_id) do
    Logger.error("Invalid series ID: #{inspect(series_id)} - expected positive integer")
    {:error, "Invalid series ID"}
  end

  # Helper function to validate movie ID from movie file response
  defp validate_movie_id(nil) do
    Logger.error("Movie ID is null - movie file may be orphaned or invalid")
    {:error, "Movie ID is null"}
  end

  defp validate_movie_id(movie_id) when is_integer(movie_id) and movie_id > 0 do
    {:ok, movie_id}
  end

  defp validate_movie_id(movie_id) do
    Logger.error("Invalid movie ID: #{inspect(movie_id)} - expected positive integer")
    {:error, "Invalid movie ID"}
  end

  def delete_video_and_vmafs(path) do
    case Media.delete_videos_with_path(path) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # Helper functions to extract year from raw API file data
  defp extract_year_from_raw_file(file, service_type) do
    case service_type do
      :sonarr ->
        # For Sonarr, try episode air date first, then fallback to filename
        case parse_episode_air_year(file) do
          year when is_integer(year) -> year
          nil -> extract_year_from_filename(file["path"])
        end

      :radarr ->
        # For Radarr, extract from file path as fallback
        extract_year_from_filename(file["path"])
    end
  end

  # Extract year from episode air date
  defp parse_episode_air_year(file) do
    air_date_str = file["airDateUtc"] || file["airDate"]

    case parse_date_string(air_date_str) do
      %Date{year: year} when year >= 1950 and year <= 2030 -> year
      _ -> nil
    end
  end

  # Parse date string to Date struct
  defp parse_date_string(nil), do: nil
  defp parse_date_string(""), do: nil

  defp parse_date_string(date_string) when is_binary(date_string) do
    case Date.from_iso8601(String.slice(date_string, 0, 10)) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp parse_date_string(_), do: nil

  # Extract year from filename as fallback using the centralized high-performance Parsers function
  defp extract_year_from_filename(path) do
    Parsers.extract_year_from_text(path)
  end

  defp schedule_sync do
    interval = Application.get_env(:reencodarr, :sync_interval_ms, @default_sync_interval_ms)
    Process.send_after(self(), :periodic_sync, interval)
  end
end
