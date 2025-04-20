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
          max_concurrency: 5,
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

  defp upsert_video_from_file(file, service_type) do
    audio_codec = CodecMapper.map_codec_id(file["mediaInfo"]["audioCodec"])
    resolution = file["mediaInfo"]["resolution"] || "0x0"
    [width, height] = String.split(resolution, "x") |> Enum.map(&String.to_integer/1)

    mediainfo = %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => file["mediaInfo"]["audioStreamCount"],
            "OverallBitRate" =>
              file["mediaInfo"]["overallBitrate"] || file["mediaInfo"]["videoBitrate"],
            "Duration" => CodecHelper.parse_duration(file["mediaInfo"]["runTime"]),
            "FileSize" => file["size"],
            "TextCount" => length(String.split(file["mediaInfo"]["subtitles"] || "", "/")),
            "VideoCount" => 1,
            "Title" => file["title"]
          },
          %{
            "@type" => "Video",
            "FrameRate" => file["mediaInfo"]["videoFps"],
            "Height" => height,
            "Width" => width,
            "HDR_Format" => file["mediaInfo"]["videoDynamicRange"],
            "HDR_Format_Compatibility" => file["mediaInfo"]["videoDynamicRangeType"],
            "CodecID" => CodecMapper.map_codec_id(file["mediaInfo"]["videoCodec"])
          },
          %{
            "@type" => "Audio",
            "CodecID" => audio_codec,
            "Channels" => to_string(CodecMapper.map_channels(file["mediaInfo"]["audioChannels"])),
            "Format_Commercial_IfAny" => CodecMapper.format_commercial_if_any(audio_codec)
          }
        ]
      }
    }

    bitrate = file["mediaInfo"]["overallBitrate"] || file["mediaInfo"]["videoBitrate"]

    attrs = %{
      "path" => file["path"],
      "size" => file["size"],
      "service_id" => to_string(file["id"]),
      "service_type" => service_type,
      "mediainfo" => mediainfo,
      "bitrate" => bitrate
    }

    if is_nil(file["size"]), do: Logger.warning("File size is missing: #{inspect(file)}")

    if audio_codec in ["TrueHD", "EAC3"] or bitrate == 0 do
      Reencodarr.Analyzer.process_path(%{
        path: file["path"],
        service_id: to_string(file["id"]),
        service_type: service_type
      })
    else
      Media.upsert_video(attrs)
    end

    :ok
  end

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
end
