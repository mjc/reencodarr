defmodule Reencodarr.Sync do
  @moduledoc "Coordinates fetching items from Sonarr/Radarr and syncing them into the database."
  use GenServer
  require Logger
  alias Reencodarr.{Media, Repo, Services, Telemetry}
  alias Reencodarr.Media.{MediaInfo, VideoFileInfo}

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
    batch
    |> Task.async_stream(&fetch_and_upsert_files(&1["id"], get_files, service_type),
      max_concurrency: 5,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Stream.with_index(batch_index * 50)
    |> Stream.each(&handle_task_result(&1, total_items, service_type))
    |> Stream.run()
  end

  defp handle_task_result({res, idx}, total_items, service_type) do
    progress = div((idx + 1) * 100, total_items)
    Telemetry.emit_sync_progress(progress, service_type)

    if not match?({:ok, :ok}, res), do: Logger.error("Sync error: #{inspect(res)}")
  end

  defp fetch_and_upsert_files(id, get_files, service_type) do
    case get_files.(id) do
      {:ok, %Req.Response{body: files}} when is_list(files) ->
        Enum.each(files, &upsert_video_from_file(&1, service_type))

      _ ->
        Logger.error("Fetch files error for id #{inspect(id)}")
    end

    :ok
  end

  def upsert_video_from_file(%VideoFileInfo{size: nil} = file, service_type) do
    Logger.warning("File size is missing: #{inspect(file)}")
    process_video_file(file, service_type)
  end

  def upsert_video_from_file(%VideoFileInfo{} = file, service_type) do
    process_video_file(file, service_type)
  end

  def upsert_video_from_file(
        %{"path" => _path, "size" => _size, "mediaInfo" => media_info} = file,
        service_type
      ) do
    info = build_video_file_info(file, media_info, service_type)
    upsert_video_from_file(info, service_type)
  end

  @doc """
  Process raw service file data directly using MediaInfo conversion.
  This bypasses the VideoFileInfo struct for simpler processing.
  """
  def upsert_video_from_service_file(file, service_type)
      when service_type in [:sonarr, :radarr] do
    # Convert directly to MediaInfo format
    mediainfo = MediaInfo.from_service_file(file, service_type)

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

  defp build_video_file_info(file, media_info, service_type) do
    # Parse resolution safely
    {width, height} =
      case {media_info["width"], media_info["height"]} do
        {w, h} when is_integer(w) and is_integer(h) ->
          {w, h}

        {w, h} when is_binary(w) and is_binary(h) ->
          with {width_int, ""} <- Integer.parse(w),
               {height_int, ""} <- Integer.parse(h) do
            {width_int, height_int}
          else
            _ -> {0, 0}
          end

        _ ->
          {0, 0}
      end

    %VideoFileInfo{
      path: file["path"],
      size: file["size"],
      service_id: to_string(file["id"]),
      service_type: service_type,
      audio_codec: media_info["audioCodec"],
      bitrate: calculate_bitrate(media_info),
      audio_channels: media_info["audioChannels"],
      video_codec: media_info["videoCodec"],
      resolution: {width, height},
      video_fps: file["videoFps"],
      video_dynamic_range: media_info["videoDynamicRange"],
      video_dynamic_range_type: media_info["videoDynamicRangeType"],
      audio_stream_count: length(parse_list_or_binary(media_info["audioLanguages"])),
      overall_bitrate: file["overallBitrate"],
      run_time: file["runTime"],
      subtitles: parse_list_or_binary(media_info["subtitles"]),
      title: file["sceneName"],
      date_added: file["dateAdded"]
    }
  end

  defp calculate_bitrate(media_info) do
    case media_info["videoBitrate"] || 0 do
      0 -> 0
      video_bitrate -> video_bitrate + (media_info["audioBitrate"] || 0)
    end
  end

  defp parse_list_or_binary(value) do
    cond do
      is_list(value) -> value
      is_binary(value) -> String.split(value, "/")
      true -> []
    end
  end

  defp process_video_file(
         %VideoFileInfo{audio_codec: codec, bitrate: 0} = info,
         service_type
       )
       when codec in ["TrueHD", "EAC3"] do
    Repo.checkout(fn ->
      Reencodarr.Analyzer.process_path(%{
        path: info.path,
        service_id: info.service_id,
        service_type: to_string(service_type)
      })
    end)
  end

  defp process_video_file(
         %VideoFileInfo{bitrate: 0} = info,
         service_type
       ) do
    Logger.debug("Bitrate is zero, inserting to DB then analyzing video: #{info.path}")

    # Convert VideoFileInfo to MediaInfo format for database storage
    mediainfo = MediaInfo.from_video_file_info(info)

    Repo.checkout(fn ->
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

    # Then send to analyzer for processing
    Reencodarr.Analyzer.process_path(%{
      path: info.path,
      service_id: info.service_id,
      service_type: to_string(service_type)
    })
  end

  defp process_video_file(
         %VideoFileInfo{} = info,
         _service_type
       ) do
    # Convert VideoFileInfo to MediaInfo format for database storage
    mediainfo = MediaInfo.from_video_file_info(info)

    Repo.checkout(fn ->
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
