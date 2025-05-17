defmodule Reencodarr.Media.VideoFileInfo do
  @moduledoc false
  defstruct [
    :path,
    :size,
    :service_id,
    :service_type,
    :audio_codec,
    :bitrate,
    :audio_channels,
    :video_codec,
    :resolution,
    :video_fps,
    :video_dynamic_range,
    :video_dynamic_range_type,
    :audio_stream_count,
    :overall_bitrate,
    :run_time,
    :subtitles,
    :title
  ]
end

defmodule Reencodarr.Sync do
  use GenServer
  require Logger
  alias Reencodarr.{Media, Services, Media.CodecMapper, Media.CodecHelper}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def sync_episodes, do: GenServer.cast(__MODULE__, :sync_episodes)
  def sync_movies, do: GenServer.cast(__MODULE__, :sync_movies)
  def init(state), do: {:ok, state}

  def handle_cast(action, state) when action in [:sync_episodes, :sync_movies] do
    {get_items, get_files, service_type} =
      case action do
        :sync_episodes -> {&Services.get_shows/0, &Services.get_episode_files/1, :sonarr}
        :sync_movies -> {&Services.get_movies/0, &Services.get_movie_files/1, :radarr}
      end

    Task.start(fn -> do_sync(state, get_items, get_files, service_type) end)
    {:noreply, state}
  end

  def handle_cast(:refresh_and_rename_series, state) do
    Task.start(fn -> Services.Sonarr.refresh_and_rename_all_series() end)
    {:noreply, state}
  end

  defp do_sync(state, get_items, get_files, service_type) do
    case get_items.() do
      {:ok, %Req.Response{body: items}} when is_list(items) ->
        items_count = length(items)

        items
        |> Task.async_stream(
          &fetch_and_upsert_files(&1["id"], get_files, service_type),
          max_concurrency: 10,
          timeout: 60_000,
          on_timeout: :kill_task
        )
        |> Stream.with_index()
        |> Enum.each(fn {res, idx} ->
          progress = div((idx + 1) * 100, items_count)
          Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:sync_progress, progress})
          if !match?({:ok, :ok}, res), do: Logger.error("Sync error: #{inspect(res)}")
        end)

      _ ->
        Logger.error("Sync error: unexpected response")
    end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", :sync_complete)
    {:noreply, state}
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

  def upsert_video_from_file(file, service_type) do
    info = build_video_file_info(file, service_type)

    if is_nil(info.size), do: Logger.warning("File size is missing: #{inspect(file)}")

    if needs_analysis?(info) do
      Reencodarr.Analyzer.process_path(%{
        path: info.path,
        service_id: info.service_id,
        service_type: info.service_type
      })
    else
      mediainfo = Reencodarr.Media.MediaInfo.from_video_file_info(info)

      Media.upsert_video(%{
        "path" => info.path,
        "size" => info.size,
        "service_id" => info.service_id,
        "service_type" => info.service_type,
        "mediainfo" => mediainfo,
        "bitrate" => info.bitrate
      })
    end

    :ok
  end

  defp needs_analysis?(%{audio_codec: c, bitrate: b}) when c in ["TrueHD", "EAC3"] or b == 0,
    do: true

  defp needs_analysis?(_), do: false

  defp build_video_file_info(file, service_type) do
    media = file["mediaInfo"] || %{}
    {width, height} = CodecHelper.parse_resolution(media["resolution"])

    %Reencodarr.Media.VideoFileInfo{
      path: file["path"],
      size: file["size"],
      service_id: to_string(file["id"]),
      service_type: service_type,
      audio_codec: CodecMapper.map_codec_id(media["audioCodec"]),
      video_codec: CodecMapper.map_codec_id(media["videoCodec"]),
      bitrate: media["overallBitrate"] || media["videoBitrate"],
      audio_channels: CodecMapper.map_channels(media["audioChannels"]),
      resolution: {width, height},
      video_fps: media["videoFps"],
      video_dynamic_range: media["videoDynamicRange"],
      video_dynamic_range_type: media["videoDynamicRangeType"],
      audio_stream_count: media["audioStreamCount"],
      overall_bitrate: media["overallBitrate"],
      run_time: media["runTime"],
      subtitles: normalize_subtitles(media["subtitles"]),
      title: file["title"]
    }
  end

  defp normalize_subtitles(nil), do: []
  defp normalize_subtitles(subs) when is_binary(subs), do: String.split(subs, "/")
  defp normalize_subtitles(subs) when is_list(subs), do: subs

  def refresh_operations(file_id, :sonarr) do
    with {:ok, %Req.Response{body: episode_file}} <- Services.Sonarr.get_episode_file(file_id),
         {:ok, _} <- Services.Sonarr.refresh_series(episode_file["seriesId"]),
         {:ok, _} <- Services.Sonarr.rename_files(episode_file["seriesId"]) do
      {:ok, "Refresh and rename triggered"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: id}),
    do: refresh_operations(id, :sonarr)

  def rescan_and_rename_series(episode_file_id),
    do: refresh_operations(episode_file_id, :sonarr)

  def delete_video_and_vmafs(path) do
    case Reencodarr.Media.delete_videos_with_path(path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
