defmodule Reencodarr.Media.MediaInfo do
  @moduledoc """
  Centralized logic for converting between VideoFileInfo structs and mediainfo maps,
  and extracting params for Ecto changesets from mediainfo maps.
  """
  alias Reencodarr.Media.{CodecHelper, CodecMapper, VideoFileInfo}

  @doc """
  Build a mediainfo map from a VideoFileInfo struct.
  """
  def from_video_file_info(%VideoFileInfo{} = info) do
    {width, height} = info.resolution
    %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => info.audio_stream_count,
            "OverallBitRate" => info.overall_bitrate || info.bitrate,
            "Duration" => CodecHelper.parse_duration(info.run_time),
            "FileSize" => info.size,
            "TextCount" => length(info.subtitles || []),
            "VideoCount" => 1,
            "Title" => info.title
          },
          %{
            "@type" => "Video",
            "FrameRate" => info.video_fps,
            "Height" => height,
            "Width" => width,
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
  Extracts params for Ecto changeset from a mediainfo map and path.
  Returns a map suitable for passing to Video.changeset/2.
  """
  def to_video_params(mediainfo, path) do
    alias Reencodarr.Media.Video
    tracks = mediainfo["media"]["track"] || []
    general = CodecHelper.get_track(mediainfo, "General") || %{}
    video_tracks = Enum.filter(tracks, &(&1["@type"] == "Video"))
    audio_tracks = Enum.filter(tracks, &(&1["@type"] == "Audio"))
    last_video = List.last(video_tracks)
    video_codecs = Enum.map(video_tracks, & &1["CodecID"])
    audio_codecs = Enum.map(audio_tracks, &Map.get(&1, "CodecID"))
    frame_rate = CodecHelper.parse_float(last_video && last_video["FrameRate"], 0.0)
    height = CodecHelper.parse_int(last_video && last_video["Height"], 0)
    width = CodecHelper.parse_int(last_video && last_video["Width"], 0)
    hdr = CodecHelper.parse_hdr([
      last_video && last_video["HDR_Format"],
      last_video && last_video["HDR_Format_Compatibility"],
      last_video && last_video["transfer_characteristics"]
    ])
    atmos = Enum.any?(audio_tracks, fn t ->
      String.contains?(Map.get(t, "Format_AdditionalFeatures", ""), "JOC") or
        String.contains?(Map.get(t, "Format_Commercial_IfAny", ""), "Atmos")
    end)
    max_audio_channels =
      audio_tracks
      |> Enum.map(&CodecHelper.parse_int(Map.get(&1, "Channels", "0"), 0))
      |> Enum.max(fn -> 0 end)
    %{
      audio_codecs: audio_codecs,
      audio_count: CodecHelper.parse_int(general["AudioCount"], 0),
      atmos: atmos,
      bitrate: CodecHelper.parse_int(general["OverallBitRate"], 0),
      duration: CodecHelper.parse_float(general["Duration"], 0.0),
      frame_rate: frame_rate,
      hdr: hdr,
      height: height,
      max_audio_channels: max_audio_channels,
      size: CodecHelper.parse_int(general["FileSize"], 0),
      text_count: CodecHelper.parse_int(general["TextCount"], 0),
      video_codecs: video_codecs,
      video_count: CodecHelper.parse_int(general["VideoCount"], 0),
      width: width,
      reencoded: reencoded?(video_codecs, mediainfo),
      title: general["Title"] || Path.basename(path)
    }
  end

  @doc """
  Returns true if the video is considered reencoded based on codecs and mediainfo.
  """
  def reencoded?(video_codecs, mediainfo) do
    alias Reencodarr.Media.CodecMapper
    Enum.any?([
      CodecMapper.has_av1_codec?(video_codecs),
      CodecMapper.has_opus_audio?(mediainfo),
      CodecMapper.low_bitrate_1080p?(video_codecs, mediainfo),
      CodecMapper.has_low_resolution_hevc?(video_codecs, mediainfo)
    ])
  end
end
