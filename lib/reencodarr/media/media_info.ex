defmodule Reencodarr.Media.MediaInfo do
  @moduledoc """
  Essential MediaInfo utility functions.

  This module now contains only the core utility functions needed for MediaInfo processing.
  The complex track extraction has been moved to MediaInfoExtractor for better performance.
  """
  # Only needed for converting TO MediaInfo format
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Media.{CodecMapper, VideoFileInfo}

  @doc """
  Parses HDR format information from a list of format strings.
  """
  def parse_hdr(formats) do
    formats
    |> Enum.reduce([], fn format, acc ->
      if format &&
           (String.contains?(format, "Dolby Vision") || String.contains?(format, "HDR") ||
              String.contains?(format, "PQ") || String.contains?(format, "SMPTE")) do
        [format | acc]
      else
        acc
      end
    end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  @doc """
  Parses HDR information from video format data.
  """
  @spec parse_hdr_from_video(nil | map()) :: String.t() | nil
  def parse_hdr_from_video(nil), do: nil

  def parse_hdr_from_video(%{} = video) do
    parse_hdr([
      video["HDR_Format"],
      video["HDR_Format_Compatibility"],
      video["transfer_characteristics"]
    ])
  end

  @doc """
  Parses subtitle information from various input formats.
  """
  @spec parse_subtitles(String.t() | list() | nil) :: list()
  def parse_subtitles(subtitles) do
    cond do
      is_binary(subtitles) -> String.split(subtitles, "/")
      is_list(subtitles) -> subtitles
      true -> []
    end
  end

  @doc """
  Check if an audio format contains Atmos.
  """
  @spec has_atmos_format?(String.t() | nil) :: boolean()
  def has_atmos_format?(nil), do: false

  def has_atmos_format?(format) when is_binary(format) do
    String.contains?(format, "Atmos")
  end

  def has_atmos_format?(_), do: false

  @doc """
  Converts VideoFileInfo struct to MediaInfo JSON format for legacy compatibility.
  """
  def from_video_file_info(%VideoFileInfo{} = info) do
    %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => info.audio_stream_count,
            "OverallBitRate" => info.overall_bitrate || info.bitrate,
            "Duration" => Parsers.parse_duration(info.run_time),
            "FileSize" => info.size,
            "TextCount" => length(info.subtitles || []),
            "VideoCount" => 1,
            "Title" => info.title
          },
          %{
            "@type" => "Video",
            "FrameRate" => info.video_fps,
            "Height" => elem(info.resolution, 1),
            "Width" => elem(info.resolution, 0),
            "HDR_Format" => info.video_dynamic_range,
            "HDR_Format_Compatibility" => info.video_dynamic_range_type,
            "CodecID" => info.video_codec
          },
          %{
            "@type" => "Audio",
            "CodecID" => info.audio_codec,
            "Channels" => to_string(info.audio_channels),
            "Format_Commercial_IfAny" => CodecMapper.format_commercial_if_any(info.audio_codec)
          }
        ]
      }
    }
  end

  @doc """
  Converts raw Sonarr/Radarr file data to VideoFileInfo for legacy compatibility.
  """
  def video_file_info_from_file(file, service_type) do
    media = file["mediaInfo"] || %{}
    {width, height} = Parsers.parse_resolution(media["resolution"])

    %VideoFileInfo{
      path: file["path"],
      size: file["size"],
      service_id: to_string(file["id"]),
      service_type: service_type,
      audio_codec: CodecMapper.map_codec_id(media["audioCodec"]),
      video_codec: CodecMapper.map_codec_id(media["videoCodec"]),
      bitrate: media["overallBitrate"] || media["videoBitrate"],
      audio_channels: CodecMapper.map_channels_with_context(media["audioChannels"], media),
      resolution: {width, height},
      video_fps: media["videoFps"],
      video_dynamic_range: media["videoDynamicRange"],
      video_dynamic_range_type: media["videoDynamicRangeType"],
      audio_stream_count: media["audioStreamCount"],
      overall_bitrate: media["overallBitrate"],
      run_time: media["runTime"],
      subtitles: parse_subtitles(media["subtitles"]),
      title: file["title"]
    }
  end
end
