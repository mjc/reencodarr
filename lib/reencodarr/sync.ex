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

  # Server Callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_cast(:sync_episode_files, state) do
    case Services.Sonarr.get_shows() do
      {:ok, %Req.Response{body: shows}} ->
        total_shows = length(shows)
        shows
        |> Enum.with_index()
        |> Enum.each(fn {show, index} ->
          fetch_and_upsert_episode_files(show["id"])
          progress = div((index + 1) * 100, total_shows)
          Logger.debug("Sync progress: #{progress}%")
          Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:sync_progress, progress})
        end)

      {:error, reason} ->
        Logger.error("Failed to sync episode files: #{inspect(reason)}")
    end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", :sync_complete)
    {:noreply, state}
  end

  defp fetch_and_upsert_episode_files(series_id) do
    case Services.Sonarr.get_episode_files(series_id) do
      {:ok, %Req.Response{body: files}} ->
        files
        |> Enum.map(&upsert_video_from_episode_file/1)
        |> Enum.each(fn
          :ok -> :ok
          error -> Logger.error("Failed to upsert video: #{inspect(error)}")
        end)

      {:error, _} ->
        []
    end
  end

  def upsert_video_from_episode_file(episode_file) do
    audio_codec = episode_file["mediaInfo"]["audioCodec"]

    mediainfo = %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => episode_file["mediaInfo"]["audioStreamCount"],
            "OverallBitRate" => episode_file["mediaInfo"]["videoBitrate"],
            "Duration" => parse_duration(episode_file["mediaInfo"]["runTime"]),
            "FileSize" => episode_file["size"],
            "TextCount" => length(String.split(episode_file["mediaInfo"]["subtitles"], "/")),
            "VideoCount" => 1,
            "Title" => episode_file["title"]
          },
          %{
            "@type" => "Video",
            "FrameRate" => episode_file["mediaInfo"]["videoFps"],
            "Height" =>
              String.split(episode_file["mediaInfo"]["resolution"], "x")
              |> List.last()
              |> String.to_integer(),
            "Width" =>
              String.split(episode_file["mediaInfo"]["resolution"], "x")
              |> List.first()
              |> String.to_integer(),
            "HDR_Format" => episode_file["mediaInfo"]["videoDynamicRange"],
            "HDR_Format_Compatibility" => episode_file["mediaInfo"]["videoDynamicRangeType"],
            "CodecID" => map_codec_id(episode_file["mediaInfo"]["videoCodec"])
          },
          %{
            "@type" => "Audio",
            "CodecID" => map_codec_id(audio_codec),
            "Channels" => to_string(map_channels(episode_file["mediaInfo"]["audioChannels"]))
          }
        ]
      }
    }

    attrs = %{
      "path" => episode_file["path"],
      "size" => episode_file["size"],
      "service_id" => to_string(episode_file["id"]),
      "service_type" => :sonarr,
      "mediainfo" => mediainfo
    }

    if audio_codec in ["TrueHD", "EAC3", "EAC3 Atmos", "TrueHD Atmos"] do
      Reencodarr.Analyzer.process_path(%{
        path: episode_file["path"],
        service_id: to_string(episode_file["id"]),
        service_type: :sonarr
      })
    else
      Media.upsert_video(attrs)
    end

    :ok
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
  defp map_codec_id("DTS-HD MA"), do: "A_DTS/MA"
  defp map_codec_id("DTS"), do: "A_DTS"
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

  defp map_channels(channels) when is_binary(channels) do
    channels
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> Enum.sum()
  end

  defp map_channels(channels) when is_number(channels), do: round(channels)
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

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: episode_file_id}) do
    with {:ok, %Req.Response{body: episode_file}} <-
           Services.Sonarr.get_episode_file(episode_file_id),
         {:ok, _refresh_series} <- Services.Sonarr.refresh_series(episode_file["seriesId"]),
         {:ok, _rename_files} <- Services.Sonarr.rename_files(episode_file["seriesId"]) do
      {:ok, "Refresh and rename triggered successfully"}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
