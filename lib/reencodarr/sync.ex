defmodule Reencodarr.Sync do
  @moduledoc "Coordinates fetching items from Sonarr/Radarr and syncing them into the database."
  use GenServer
  require Logger
  import Ecto.Query
  alias Reencodarr.{Media, Repo, Services, Telemetry}
  alias Reencodarr.Media.Video.MediaInfoConverter
  alias Reencodarr.Media.VideoFileInfo

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

    Telemetry.emit_sync_started(service_type)
    sync_items(get_items, get_files, service_type)
    Telemetry.emit_sync_completed(service_type)

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
    # Collect all files from all items in this batch
    all_files = 
      batch
      |> Task.async_stream(&fetch_and_upsert_files(&1["id"], get_files, service_type),
        max_concurrency: 5,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, files} when is_list(files) -> files
        _ -> []
      end)

    # Process all files in a single batch operation
    if length(all_files) > 0 do
      batch_upsert_videos(all_files, service_type)
    end

    # Update progress
    progress = div((batch_index + 1) * 50 * 100, total_items)
    Telemetry.emit_sync_progress(min(progress, 100), service_type)
  end

  defp batch_upsert_videos(files, service_type) do
    # Pre-fetch all library mappings to avoid N+1 queries
    library_mappings = preload_library_mappings()
    
    # Process files and prepare for batch upsert
    video_attrs_list = 
      files
      |> Enum.map(&prepare_video_attrs(&1, service_type, library_mappings))
      |> Enum.reject(&is_nil/1)
    
    # Group files that need analysis
    {files_needing_analysis, _} = 
      Enum.split_with(video_attrs_list, fn attrs -> 
        Map.get(attrs, "bitrate", 0) == 0 
      end)
    
    # Perform batch upsert in a single transaction
    Repo.transaction(fn ->
      Enum.each(video_attrs_list, fn attrs ->
        Media.VideoUpsert.upsert(attrs)
      end)
      
      # Batch send files for analysis
      if length(files_needing_analysis) > 0 do
        analysis_items = Enum.map(files_needing_analysis, fn attrs ->
          %{
            path: attrs["path"],
            service_id: attrs["service_id"],
            service_type: attrs["service_type"]
          }
        end)
        
        # Send batch to analyzer (assuming it can handle batches)
        Enum.each(analysis_items, &Reencodarr.Analyzer.process_path/1)
      end
    end, timeout: :infinity)
  end
  
  defp preload_library_mappings do
    # Pre-fetch all libraries to avoid repeated queries
    Repo.all(
      from l in Media.Library,
        select: %{id: l.id, path: l.path}
    )
    |> Enum.sort_by(& &1.path, :desc)  # Sort by path length desc for proper matching
  end
  
  defp find_library_id_from_cache(path, library_mappings) do
    library_mappings
    |> Enum.find(fn lib -> String.starts_with?(path, lib.path) end)
    |> case do
      %{id: id} -> id
      nil -> nil
    end
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
          "dateAdded" => raw_file["dateAdded"]
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
          "dateAdded" => info.date_added
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

  defp process_single_video_file(%VideoFileInfo{} = info, service_type) do
    # Convert VideoFileInfo to MediaInfo format for database storage
    mediainfo = MediaInfoConverter.from_video_file_info(info)

    result = Repo.transaction(fn ->
      Media.upsert_video(%{
        "path" => info.path,
        "size" => info.size,
        "service_id" => info.service_id,
        "service_type" => to_string(info.service_type),
        "mediainfo" => mediainfo,
        "bitrate" => info.bitrate,
        "dateAdded" => info.date_added
      })
    end)

    # Send for analysis if bitrate is missing
    if info.bitrate == 0 do
      Reencodarr.Analyzer.process_path(%{
        path: info.path,
        service_id: info.service_id,
        service_type: to_string(service_type)
      })
    end
    
    result
  end

  @doc """
  Process raw service file data directly using MediaInfo conversion.
  This bypasses the VideoFileInfo struct for simpler processing.
  """
  def upsert_video_from_service_file(file, service_type)
      when service_type in [:sonarr, :radarr] do
    # Convert directly to MediaInfo format
    mediainfo = MediaInfoConverter.from_service_file(file, service_type)

    # Check if we need to analyze due to missing bitrate
    needs_analysis =
      case get_in(mediainfo, ["media", "track"]) do
        tracks when is_list(tracks) ->
          Enum.any?(tracks, fn track ->
            track["@type"] == "General" and
              (track["OverallBitRate"] == 0 or is_nil(track["OverallBitRate"]))
          end)

        _ ->
          true
      end

    # Store in database
    Repo.checkout(fn ->
      Media.upsert_video(%{
        "path" => file["path"],
        "size" => file["size"],
        "service_id" => to_string(file["id"]),
        "service_type" => to_string(service_type),
        "mediainfo" => mediainfo,
        "bitrate" => file["overallBitrate"] || 0,
        "dateAdded" => file["dateAdded"]
      })
    end)

    # Send for analysis if needed
    if needs_analysis do
      Reencodarr.Analyzer.process_path(%{
        path: file["path"],
        service_id: to_string(file["id"]),
        service_type: to_string(service_type)
      })
    end
  end

  defp build_video_file_info(file, _media_info, service_type) do
    # Use the new converter
    MediaInfoConverter.video_file_info_from_file(file, service_type)
  end

  def refresh_operations(file_id, :sonarr) do
    with {:ok, %Req.Response{body: episode_file}} <- Services.Sonarr.get_episode_file(file_id),
         {:ok, _} <- Services.Sonarr.refresh_series(episode_file["seriesId"]),
         {:ok, _} <-
           Services.Sonarr.rename_files(episode_file["seriesId"], [String.to_integer(file_id)]) do
      {:ok, "Refresh and rename triggered"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_operations(file_id, :radarr) do
    with {:ok, %Req.Response{body: movie_file}} <- Services.Radarr.get_movie_file(file_id),
         {:ok, _} <- Services.Radarr.refresh_movie(movie_file["movieId"]),
         {:ok, _} <- Services.Radarr.rename_movie_files(movie_file["movieId"]) do
      {:ok, "Refresh triggered for Radarr"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: id}),
    do: refresh_operations(id, :sonarr)

  def refresh_and_rename_from_video(%{service_type: :radarr, service_id: id}),
    do: refresh_operations(id, :radarr)

  def rescan_and_rename_series(id), do: refresh_operations(id, :sonarr)

  def delete_video_and_vmafs(path) do
    case Reencodarr.Media.delete_videos_with_path(path) do
      {:ok, _} -> :ok
      err -> err
    end
  end
end
