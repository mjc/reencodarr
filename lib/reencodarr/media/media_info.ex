defmodule Reencodarr.Media.MediaInfo do
  @moduledoc """
  Logic for converting between VideoFileInfo structs and mediainfo maps, and extracting params for Ecto changesets.
  """
  alias Reencodarr.Media.{CodecHelper, CodecMapper, VideoFileInfo}

  def from_video_file_info(%VideoFileInfo{} = info) do
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

  def to_video_params(mediainfo, path) do
    require Logger

    # Safer access to tracks, handling nil values at any level
    tracks =
      case mediainfo do
        %{"media" => %{"track" => tracks}} when is_list(tracks) -> tracks
        %{"media" => %{"track" => track}} when is_map(track) -> [track]  # Handle single track as a map
        %{"media" => nil} -> []
        nil -> []
        _ ->
          # Log unexpected structure but don't crash
          Logger.warning("Unexpected mediainfo structure for #{path}: #{inspect(mediainfo, pretty: true, limit: 1000)}")
          []
      end

    general = CodecHelper.get_track(mediainfo, "General") || %{}
    video_tracks = Enum.filter(tracks, &(&1["@type"] == "Video"))
    audio_tracks = Enum.filter(tracks, &(&1["@type"] == "Audio"))
    last_video = List.last(video_tracks)
    video_codecs = Enum.map(video_tracks, &Map.get(&1, "CodecID"))

    # Log structure in case of issues
    if Enum.empty?(video_tracks) do
      Logger.warning("No video tracks found for #{path}: #{inspect(mediainfo, pretty: true, limit: 1000)}")
      Logger.warning("Parsed tracks: #{inspect(tracks, pretty: true, limit: 1000)}")
      Logger.warning("video_codecs will be: #{inspect(video_codecs)}")
    end

    # Additional debugging for video_codecs
    if video_codecs == nil do
      Logger.error("❌ CRITICAL: video_codecs extracted as nil!")
      Logger.error("video_tracks: #{inspect(video_tracks)}")
      Logger.error("Full mediainfo: #{inspect(mediainfo, pretty: true, limit: :infinity)}")
      raise "video_codecs is nil after extraction - this indicates a bug"
    end

    %{
      audio_codecs: Enum.map(audio_tracks, &Map.get(&1, "CodecID")),
      audio_count: CodecHelper.parse_int(general["AudioCount"], 0),
      atmos: CodecHelper.has_atmos?(audio_tracks),
      bitrate: CodecHelper.parse_int(general["OverallBitRate"], 0),
      duration: CodecHelper.parse_float(general["Duration"], 0.0),
      frame_rate: CodecHelper.parse_float(last_video && Map.get(last_video, "FrameRate"), 0.0),
      hdr: CodecHelper.parse_hdr_from_video(last_video),
      height: CodecHelper.parse_int(last_video && Map.get(last_video, "Height"), 0),
      max_audio_channels: CodecHelper.max_audio_channels(audio_tracks),
      size: CodecHelper.parse_int(general["FileSize"], 0),
      text_count: CodecHelper.parse_int(general["TextCount"], 0),
      video_codecs: video_codecs,
      video_count: CodecHelper.parse_int(general["VideoCount"], 0),
      width: CodecHelper.parse_int(last_video && Map.get(last_video, "Width"), 0),
      reencoded: reencoded?(video_codecs, mediainfo),
      title: Map.get(general, "Title") || Path.basename(path)
    }
  end

  def reencoded?(video_codecs, mediainfo),
    do:
      CodecMapper.has_av1_codec?(video_codecs) or
        CodecMapper.has_opus_audio?(mediainfo) or
        CodecMapper.low_bitrate_1080p?(video_codecs, mediainfo) or
        CodecMapper.has_low_resolution_hevc?(video_codecs, mediainfo)

  def video_file_info_from_file(file, service_type) do
    media = file["mediaInfo"] || %{}
    {width, height} = CodecHelper.parse_resolution(media["resolution"])

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
      subtitles: CodecHelper.parse_subtitles(media["subtitles"]),
      title: file["title"]
    }
  end
end
