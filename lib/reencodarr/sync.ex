defmodule Reencodarr.Sync do
  @moduledoc """
  This module is responsible for syncing data between services and Reencodarr.
  """
  alias Reencodarr.{Media, Services}
  alias Reencodarr.Repo
  require Logger

  def sync_episode_files do
    case Services.Sonarr.get_shows() do
      {:ok, %Req.Response{body: shows}} ->
        shows
        |> Enum.map(& &1["id"])
        |> Enum.map(&fetch_and_upsert_episode_files/1)
        |> List.flatten()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_and_upsert_episode_files(series_id) do
    case Services.Sonarr.get_episode_files(series_id) do
      {:ok, %Req.Response{body: files}} ->
        # Repo.transaction(fn ->
        Enum.map(files, &upsert_video_from_episode_file/1)

      # end)

      {:error, _} ->
        []
    end
  end

  def upsert_video_from_episode_file(episode_file) do
    audio_codec = episode_file["mediaInfo"]["audioCodec"]

    mediainfo =
      if audio_codec in ["TrueHD", "EAC3"] do
        {:ok, all_mediainfo} = Reencodarr.Analyzer.fetch_mediainfo(episode_file["path"])
        Map.get(all_mediainfo, episode_file["path"])
      else
        %{
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
      end

    attrs = %{
      "path" => episode_file["path"],
      "size" => episode_file["size"],
      "service_id" => to_string(episode_file["id"]),
      "service_type" => :sonarr,
      "mediainfo" => mediainfo
    }

    case Media.upsert_video(attrs) do
      {:ok, video} ->
        video

      {:error, changeset} ->
        Logger.error("Failed to upsert video: #{inspect(changeset)}")
        changeset
    end
  end

  defp map_codec_id("h265"), do: "V_MPEGH/ISO/HEVC"
  defp map_codec_id("x265"), do: "V_MPEGH/ISO/HEVC"
  defp map_codec_id("h264"), do: "V_MPEG4/ISO/AVC"
  defp map_codec_id("x264"), do: "V_MPEG4/ISO/AVC"
  defp map_codec_id("HEVC"), do: "V_MPEGH/ISO/HEVC"
  defp map_codec_id("AVC"), do: "V_MPEG4/ISO/AVC"
  defp map_codec_id("VP9"), do: "V_VP9"
  defp map_codec_id("VP8"), do: "V_VP8"
  defp map_codec_id("AV1"), do: "V_AV1"
  defp map_codec_id("EAC3"), do: "A_EAC3"
  defp map_codec_id("AC3"), do: "A_AC3"
  defp map_codec_id("AAC"), do: "A_AAC"
  defp map_codec_id("Opus"), do: "A_OPUS"
  defp map_codec_id("DTS"), do: "A_DTS"
  defp map_codec_id("TrueHD"), do: "A_TRUEHD"
  defp map_codec_id("DTS-HD MA"), do: "A_DTS/MA"
  defp map_codec_id("MP3"), do: "A_MPEG/L3"
  defp map_codec_id(codec), do: raise(codec)

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
