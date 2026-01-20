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

  # Public API
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def sync_episodes, do: GenServer.cast(__MODULE__, :sync_episodes)
  def sync_movies, do: GenServer.cast(__MODULE__, :sync_movies)

  # GenServer Callbacks
  def init(state), do: {:ok, state}

  def handle_cast(:refresh_and_rename_series, state) do
    Services.Sonarr.refresh_and_rename_all_series()
    {:noreply, state}
  end

  def handle_cast(action, state) when action in [:sync_episodes, :sync_movies] do
    {get_items, get_files, service_type} = resolve_action(action)

    Events.broadcast_event(:sync_started, %{service_type: service_type})
    sync_items(get_items, get_files, service_type)
    Events.broadcast_event(:sync_completed, %{service_type: service_type})

    # Trigger analyzer to process any videos that need analysis after sync completion
    AnalyzerBroadway.dispatch_available()

    {:noreply, state}
  end

  # Private Functions
  defp resolve_action(:sync_episodes),
    do: {&Services.get_shows/0, &Services.get_episode_files/1, :sonarr}

  defp resolve_action(:sync_movies),
    do: {&Services.get_movies/0, &Services.get_movie_files/1, :radarr}

  defp sync_items(get_items, get_files, service_type) do
    case get_items.() do
      {:ok, %Req.Response{body: items}} when is_list(items) ->
        process_items_in_batches(items, get_files, service_type)

      _ ->
        Logger.error("Sync error: unexpected response")
    end
  end

  defp process_items_in_batches(items, get_files, service_type) do
    items
    |> Stream.chunk_every(50)
    |> Stream.with_index()
    |> Stream.each(&process_batch(&1, get_files, service_type, length(items)))
    |> Stream.run()
  end

  defp process_batch({batch, batch_index}, get_files, service_type, total_items) do
    batch_start_time = System.monotonic_time(:millisecond)

    # Collect all files from all items in this batch
    all_files =
      batch
      |> Task.async_stream(&fetch_and_upsert_files(&1["id"], get_files, service_type),
        # Increased for better throughput
        max_concurrency: 8,
        # Reduced timeout for faster failure detection
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, files} when is_list(files) ->
          files

        {:error, reason} ->
          Logger.warning("Sync: Task failed in batch #{batch_index}: #{inspect(reason)}")
          []

        _ ->
          []
      end)

    # Process all files in a single batch operation
    files_processed =
      if Enum.empty?(all_files) do
        0
      else
        batch_upsert_videos(all_files, service_type)
        length(all_files)
      end

    # Log batch performance metrics
    batch_duration = System.monotonic_time(:millisecond) - batch_start_time

    Logger.info(
      "Sync: Batch #{batch_index} processed #{files_processed} files in #{batch_duration}ms"
    )

    # Update progress
    progress = div((batch_index + 1) * 50 * 100, total_items)

    Events.broadcast_event(:sync_progress, %{
      progress: min(progress, 100),
      service_type: service_type
    })
  end

  @doc """
  Batch upserts multiple videos with library mapping cache optimization.
  This function is exposed for testing performance optimizations.
  """
  def batch_upsert_videos(files, service_type) do
    # Pre-fetch all library mappings to avoid N+1 queries
    library_mappings = preload_library_mappings()

    # Process files and prepare for batch upsert
    video_attrs_list =
      files
      |> Enum.map(&prepare_video_attrs(&1, service_type, library_mappings))
      |> Enum.reject(&is_nil/1)

    Logger.info("Sync: Processing #{length(video_attrs_list)} videos in batch")

    perform_batch_transaction(video_attrs_list)
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
      Logger.info("Sync: Successfully processed #{success_count} videos")
    end

    :ok
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

  defp fetch_and_upsert_files(id, get_files, _service_type) do
    case get_files.(id) do
      {:ok, %Req.Response{body: files}} when is_list(files) ->
        # Collect all files for batch processing instead of individual upserts
        files

      _ ->
        Logger.error("Fetch files error for id #{inspect(id)}")
        []
    end
  end

  # Keep these functions for individual file processing (used by webhooks)
  def upsert_video_from_file(%VideoFileInfo{size: nil} = file, service_type) do
    Logger.warning("File size is missing: #{inspect(file)}")
    process_single_video_file(file, service_type)
  end

  def upsert_video_from_file(%VideoFileInfo{} = file, service_type) do
    process_single_video_file(file, service_type)
  end

  def upsert_video_from_file(
        %{"path" => _path, "size" => _size, "mediaInfo" => media_info} = file,
        service_type
      ) do
    info = build_video_file_info(file, media_info, service_type)
    upsert_video_from_file(info, service_type)
  end

  defp process_single_video_file(%VideoFileInfo{} = info, _service_type) do
    # Check if video exists and file size hasn't changed
    existing_video = Media.get_video_by_path(info.path)

    result =
      Repo.transaction(fn ->
        handle_video_upsert(existing_video, info)
      end)

    # VideoUpsert will automatically set state to needs_analysis for zero bitrate
    result
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

    # Store in database
    result =
      Repo.transaction(fn ->
        VideoUpsert.upsert(%{
          "path" => file["path"],
          "size" => file["size"],
          "service_id" => to_string(file["id"]),
          "service_type" => to_string(service_type),
          "mediainfo" => mediainfo,
          "bitrate" => file["overallBitrate"] || 0,
          "dateAdded" => file["dateAdded"]
        })
      end)

    # VideoUpsert will automatically set state to needs_analysis for missing bitrate
    result
  end

  defp build_video_file_info(file, _media_info, service_type) do
    # Use the new converter
    MediaInfoConverter.video_file_info_from_file(file, service_type)
  end

  def refresh_operations(file_id, :sonarr) do
    with {:ok, %Req.Response{body: episode_file}} <- Services.Sonarr.get_episode_file(file_id),
         {:ok, series_id} <- validate_series_id(episode_file["seriesId"]),
         {:ok, _} <- Services.Sonarr.refresh_series(series_id),
         # Wait for Sonarr to scan the file after refresh
         :ok <- Process.sleep(5000) && :ok,
         # Rename all renameable files for this series
         {:ok, _} <- Services.Sonarr.rename_files(series_id, []) do
      {:ok, "Refresh and rename triggered"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_operations(file_id, :radarr) do
    with {:ok, %Req.Response{body: movie_file}} <- Services.Radarr.get_movie_file(file_id),
         {:ok, movie_id} <- validate_movie_id(movie_file["movieId"]),
         {:ok, _} <- Services.Radarr.refresh_movie(movie_id),
         # Wait for Radarr to scan the file after refresh
         :ok <- Process.sleep(5000) && :ok,
         {:ok, _} <- Services.Radarr.rename_movie_files(movie_id, [file_id]) do
      {:ok, "Refresh and rename triggered for Radarr"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: id})
      when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> refresh_operations(int_id, :sonarr)
      _ -> {:error, "Invalid service_id: #{id}"}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: id}) when is_integer(id),
    do: refresh_operations(id, :sonarr)

  def refresh_and_rename_from_video(%{service_type: :radarr, service_id: id})
      when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> refresh_operations(int_id, :radarr)
      _ -> {:error, "Invalid service_id: #{id}"}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :radarr, service_id: id}) when is_integer(id),
    do: refresh_operations(id, :radarr)

  def refresh_and_rename_from_video(%{service_type: nil}),
    do: {:error, "No service type for video"}

  def refresh_and_rename_from_video(%{service_id: nil}),
    do: {:error, "No service_id for video"}

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
end
