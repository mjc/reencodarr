defmodule Reencodarr.Sync do
  use GenServer

  @moduledoc """
  This module is responsible for syncing data between services and Reencodarr.
  """
  alias Reencodarr.{Media, Services}
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
        |> Enum.each(fn {item, index} ->
          fetch_upsert_fun.(item["id"])
          progress = div((index + 1) * 100, total_items)
          Logger.debug("Sync progress: #{progress}%")
          Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:sync_progress, progress})
        end)

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
    audio_codec = file["mediaInfo"]["audioCodec"]

    mediainfo = %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => file["mediaInfo"]["audioStreamCount"],
            "OverallBitRate" =>
              file["mediaInfo"]["overallBitrate"] ||
                file["mediaInfo"]["videoBitrate"],
            "Duration" => parse_duration(file["mediaInfo"]["runTime"]),
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
            "CodecID" => map_codec_id(file["mediaInfo"]["videoCodec"])
          },
          %{
            "@type" => "Audio",
            "CodecID" => map_codec_id(audio_codec),
            "Channels" => to_string(map_channels(file["mediaInfo"]["audioChannels"])),
            "Format_Commercial_IfAny" => format_commercial_if_any(audio_codec)
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

  defp format_commercial_if_any(nil), do: ""

  defp format_commercial_if_any(audio_codec) do
    if audio_codec in ["TrueHD Atmos", "EAC3 Atmos", "DTS-X"], do: "Atmos", else: ""
  end

  defp map_codec_id("AV1"), do: "V_AV1"
  defp map_codec_id("x265"), do: "V_MPEGH/ISO/HEVC"
  defp map_codec_id("h265"), do: "V_MPEGH/ISO/HEVC"
  defp map_codec_id("HEVC"), do: "V_MPEGH/ISO/HEVC"
  defp map_codec_id("VP9"), do: "V_VP9"
  defp map_codec_id("VP8"), do: "V_VP8"
  defp map_codec_id("x264"), do: "V_MPEG4/ISO/AVC"
  defp map_codec_id("h264"), do: "V_MPEG4/ISO/AVC"
  defp map_codec_id("AVC"), do: "V_MPEG4/ISO/AVC"
  defp map_codec_id("XviD"), do: "V_XVID"
  defp map_codec_id("VC1"), do: "V_VC1"
  defp map_codec_id("DivX"), do: "V_DIVX"
  defp map_codec_id("MPEG2"), do: "V_MPEG2"

  defp map_codec_id("EAC3 Atmos"), do: :eac3_atmos
  defp map_codec_id("TrueHD Atmos"), do: :truehd_atmos
  defp map_codec_id("Opus"), do: "A_OPUS"
  defp map_codec_id("EAC3"), do: "A_EAC3"
  defp map_codec_id("TrueHD"), do: "A_TRUEHD"
  defp map_codec_id("DTS-X"), do: "A_DTS/X"
  defp map_codec_id("DTS-HD MA"), do: "A_DTS/MA"
  defp map_codec_id("DTS"), do: "A_DTS"
  defp map_codec_id("DTS-ES"), do: "A_DTS/ES"
  defp map_codec_id("FLAC"), do: "A_FLAC"
  defp map_codec_id("Vorbis"), do: "A_VORBIS"
  defp map_codec_id("AAC"), do: "A_AAC"
  defp map_codec_id("AC3"), do: "A_AC3"
  defp map_codec_id("MP3"), do: "A_MPEG/L3"
  defp map_codec_id("MP2"), do: "A_MPEG/L2"
  defp map_codec_id("PCM"), do: "A_PCM"

  defp map_codec_id(""), do: ""
  defp map_codec_id(nil), do: ""
  defp map_codec_id(codec), do: raise("Unknown codec: #{inspect(codec)}")

  defp map_channels("9.2"), do: 11
  defp map_channels("9.1"), do: 10
  defp map_channels("8.1"), do: 9
  defp map_channels("8"), do: 8
  defp map_channels("8.2"), do: 10
  defp map_channels("7.2"), do: 9
  defp map_channels("7.1"), do: 8
  defp map_channels("6.1"), do: 7
  defp map_channels("6"), do: 6
  defp map_channels("5.1"), do: 6
  defp map_channels("5"), do: 5
  defp map_channels("4.1"), do: 5
  defp map_channels("4"), do: 4
  defp map_channels("3.1"), do: 4
  defp map_channels("3"), do: 3
  defp map_channels("2.1"), do: 3
  defp map_channels("2"), do: 2
  defp map_channels("1"), do: 1

  defp map_channels(9.2), do: 11
  defp map_channels(9.1), do: 10
  defp map_channels(8.2), do: 10
  defp map_channels(8.1), do: 9
  defp map_channels(7.2), do: 9
  defp map_channels(7.1), do: 8
  defp map_channels(6.1), do: 7
  defp map_channels(6), do: 6
  defp map_channels(5.1), do: 6
  defp map_channels(5), do: 5
  defp map_channels(4.1), do: 5
  defp map_channels(4), do: 4
  defp map_channels(3.1), do: 4
  defp map_channels(3), do: 3
  defp map_channels(2.1), do: 3
  defp map_channels(2), do: 2
  defp map_channels(1), do: 1
  defp map_channels(_), do: 0

  defp parse_duration(duration) when is_binary(duration) do
    case String.split(duration, ":") do
      [hours, minutes, seconds] ->
        String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
          String.to_integer(seconds)

      [minutes, seconds] ->
        String.to_integer(minutes) * 60 + String.to_integer(seconds)

      [seconds] ->
        String.to_integer(seconds)

      _ ->
        0
    end
  end

  defp parse_duration(duration) when is_number(duration), do: duration
  defp parse_duration(_), do: 0
end
