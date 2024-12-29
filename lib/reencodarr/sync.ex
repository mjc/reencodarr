defmodule Reencodarr.Sync do
  use GenServer

  @moduledoc """
  This module is responsible for syncing data between services and Reencodarr.
  """
  alias Reencodarr.{Media, Services, Media.CodecMapper, Media.CodecHelper}
  require Logger

  # Client API
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def sync_episode_files do
    GenServer.cast(__MODULE__, :sync_episode_files)
  end

  def sync_movie_files do
    GenServer.cast(__MODULE__, :sync_movie_files)
  end

  # Server Callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_cast(:sync_episode_files, state),
    do:
      handle_generic_sync(state, &Services.Sonarr.get_shows/0, &fetch_and_upsert_episode_files/1)

  def handle_cast(:sync_movie_files, state),
    do: handle_generic_sync(state, &Services.Radarr.get_movies/0, &fetch_and_upsert_movie_files/1)

  defp handle_generic_sync(state, get_items_fun, fetch_upsert_fun) do
    case get_items_fun.() do
      {:ok, %Req.Response{body: items}} ->
        total_items = length(items)

        items
        |> Enum.with_index()
        |> Task.async_stream(fn {item, index} ->
          fetch_upsert_fun.(item["id"])
          progress = div((index + 1) * 100, total_items)
          Logger.debug("Sync progress: #{progress}%")
          Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:sync_progress, progress})
        end, max_concurrency: System.schedulers_online())
        |> Stream.run()

      {:error, reason} ->
        Logger.error("Sync error: #{inspect(reason)}")
    end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", :sync_complete)
    {:noreply, state}
  end

  defp fetch_and_upsert_episode_files(series_id),
    do:
      fetch_and_upsert_files(
        &Services.Sonarr.get_episode_files/1,
        &upsert_video_from_episode_file/1,
        series_id
      )

  defp fetch_and_upsert_movie_files(movie_id),
    do:
      fetch_and_upsert_files(
        &Services.Radarr.get_movie_files/1,
        &upsert_video_from_movie_file/1,
        movie_id
      )

  defp fetch_and_upsert_files(get_files_fun, upsert_fun, id) do
    case get_files_fun.(id) do
      {:ok, %Req.Response{body: files}} ->
        files
        |> Enum.map(upsert_fun)
        |> Enum.each(fn
          :ok -> :ok
          error -> Logger.error("Failed to upsert video: #{inspect(error)}")
        end)

      {:error, reason} ->
        Logger.error("Fetch files error: #{inspect(reason)}")
    end
  end

  defp upsert_video_from_episode_file(file),
    do: upsert_video_from_file(file, :sonarr)

  defp upsert_video_from_movie_file(file),
    do: upsert_video_from_file(file, :radarr)

  defp upsert_video_from_file(file, service_type) do
    audio_codec = CodecMapper.map_codec_id(file["mediaInfo"]["audioCodec"])

    mediainfo = %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => file["mediaInfo"]["audioStreamCount"],
            "OverallBitRate" =>
              file["mediaInfo"]["overallBitrate"] ||
                file["mediaInfo"]["videoBitrate"],
            "Duration" => CodecHelper.parse_duration(file["mediaInfo"]["runTime"]),
            "FileSize" => file["size"],
            "TextCount" => length(String.split(file["mediaInfo"]["subtitles"], "/")),
            "VideoCount" => 1,
            "Title" => file["title"]
          },
          %{
            "@type" => "Video",
            "FrameRate" => file["mediaInfo"]["videoFps"],
            "Height" =>
              String.split(file["mediaInfo"]["resolution"], "x")
              |> List.last()
              |> String.to_integer(),
            "Width" =>
              String.split(file["mediaInfo"]["resolution"], "x")
              |> List.first()
              |> String.to_integer(),
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

    bitrate =
      file["mediaInfo"]["overallBitrate"] || file["mediaInfo"]["videoBitrate"]

    attrs = %{
      "path" => file["path"],
      "size" => file["size"],
      "service_id" => to_string(file["id"]),
      "service_type" => service_type,
      "mediainfo" => mediainfo,
      "bitrate" => bitrate
    }

    if is_nil(file["size"]) do
      Logger.warning("File size is missing for file: #{inspect(file)}")
    end

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
         {:ok, _refresh_series} <- Services.Sonarr.refresh_series(episode_file["seriesId"]),
         {:ok, _rename_files} <- Services.Sonarr.rename_files(episode_file["seriesId"]) do
      {:ok, "Refresh and rename triggered successfully"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: id}),
    do: refresh_operations(id, :sonarr)

  # rescan the whole series and rename all files for that series. use carefully
  def rescan_and_rename_series(episode_file_id),
    do: refresh_operations(episode_file_id, :sonarr)
end
