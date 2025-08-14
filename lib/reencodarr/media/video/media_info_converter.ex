defmodule Reencodarr.Media.Video.MediaInfoConverter do
  @moduledoc """
  Converts various data sources to the new MediaInfo embedded schema format.
  This replaces the legacy MediaInfo conversion functions.
  """

  alias Reencodarr.DataConverters
  alias Reencodarr.Media.{CodecMapper, VideoFileInfo}

  @doc """
  Validates and processes MediaInfo JSON data.
  """
  def from_mediainfo_json(mediainfo) when is_map(mediainfo) do
    # Just pass through the mediainfo - this is a compatibility function
    # for any remaining legacy calls
    {:ok, mediainfo}
  end

  def from_mediainfo_json(_invalid_data) do
    {:error, "invalid mediainfo format"}
  end

  @doc """
  Converts VideoFileInfo struct to MediaInfo JSON format.
  """
  def from_video_file_info(%VideoFileInfo{} = info) do
    {width, height} = parse_resolution(info.resolution)

    %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => info.audio_stream_count,
            "OverallBitRate" => info.overall_bitrate || info.bitrate,
            "Duration" => DataConverters.parse_duration(info.run_time),
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
  Converts raw Sonarr/Radarr file data directly to MediaInfo JSON format.
  """
  def from_service_file(file, service_type) when service_type in [:sonarr, :radarr] do
    media_info = file["mediaInfo"] || %{}

    {width, height} = parse_resolution_from_service(media_info)
    overall_bitrate = calculate_overall_bitrate(file, media_info)
    subtitles = parse_subtitles_from_service(media_info)
    audio_languages = parse_audio_languages_from_service(media_info)

    %{
      "media" => %{
        "track" => [
          build_general_track(file, overall_bitrate, subtitles, audio_languages),
          build_video_track(file, media_info, width, height),
          build_audio_track(media_info)
        ]
      }
    }
  end

  @doc """
  Creates a VideoFileInfo struct from service file data.
  """
  def video_file_info_from_file(file, service_type) do
    media_info = file["mediaInfo"] || %{}

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

  # Private helper functions

  defp parse_resolution({width, height}) when is_integer(width) and is_integer(height) do
    {width, height}
  end

  defp parse_resolution(resolution) when is_binary(resolution) do
    case String.split(resolution, "x") do
      [width_str, height_str] ->
        with {width, ""} <- Integer.parse(width_str),
             {height, ""} <- Integer.parse(height_str) do
          {width, height}
        else
          _ -> {0, 0}
        end

      _ ->
        {0, 0}
    end
  end

  defp parse_resolution(_), do: {0, 0}

  defp parse_resolution_from_service(media_info) do
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
  end

  defp calculate_overall_bitrate(file, media_info) do
    case {file["overallBitrate"], media_info["videoBitrate"], media_info["audioBitrate"]} do
      {overall, _, _} when is_integer(overall) and overall > 0 -> overall
      {_, video, audio} when is_integer(video) and is_integer(audio) -> video + audio
      {_, video, _} when is_integer(video) -> video
      _ -> 0
    end
  end

  defp parse_subtitles_from_service(media_info) do
    case media_info["subtitles"] do
      list when is_list(list) -> list
      binary when is_binary(binary) -> String.split(binary, "/")
      _ -> []
    end
  end

  defp parse_audio_languages_from_service(media_info) do
    case media_info["audioLanguages"] do
      list when is_list(list) -> list
      binary when is_binary(binary) -> String.split(binary, "/")
      _ -> []
    end
  end

  defp build_general_track(file, overall_bitrate, subtitles, audio_languages) do
    duration = normalize_duration(file["runTime"])
    final_bitrate = normalize_bitrate(overall_bitrate)

    %{
      "@type" => "General",
      "AudioCount" => length(audio_languages),
      "OverallBitRate" => final_bitrate,
      "Duration" => duration,
      "FileSize" => file["size"] || 0,
      "TextCount" => length(subtitles),
      "VideoCount" => 1,
      "Title" => file["sceneName"] || file["title"]
    }
  end

  defp normalize_duration(run_time) do
    case run_time do
      # Default to 1 hour if missing
      nil -> 3600.0
      # Default to 1 hour if zero
      0 -> 3600.0
      # Convert seconds to milliseconds
      time when is_integer(time) -> time * 1000.0
      # Convert seconds to milliseconds
      time when is_float(time) -> time * 1000.0
      _ -> 3600.0
    end
  end

  defp normalize_bitrate(overall_bitrate) do
    case overall_bitrate do
      rate when is_integer(rate) and rate > 0 -> rate
      # Default to 5 Mbps if missing or zero
      _ -> 5_000_000
    end
  end

  defp build_video_track(file, media_info, width, height) do
    {final_width, final_height} = normalize_resolution(width, height)
    video_codec = media_info["videoCodec"] || "Unknown"
    frame_rate = determine_frame_rate(file, media_info)

    %{
      "@type" => "Video",
      # VideoTrack expects "Format" field
      "Format" => video_codec,
      # Keep CodecID for compatibility
      "CodecID" => video_codec,
      "FrameRate" => frame_rate,
      "Height" => final_height,
      "Width" => final_width,
      "HDR_Format" => media_info["videoDynamicRange"] || "",
      "HDR_Format_Compatibility" => media_info["videoDynamicRangeType"] || ""
    }
  end

  defp normalize_resolution(width, height) do
    case {width, height} do
      {w, h} when is_integer(w) and w > 0 and is_integer(h) and h > 0 ->
        {w, h}

      _ ->
        # Fallback to common HD resolution if we can't determine the actual resolution
        {1920, 1080}
    end
  end

  defp determine_frame_rate(file, media_info) do
    file["videoFps"] || media_info["videoFps"] || 23.976
  end

  defp build_audio_track(media_info) do
    audio_codec = media_info["audioCodec"] || "Unknown"

    %{
      "@type" => "Audio",
      # AudioTrack expects "Format" field
      "Format" => audio_codec,
      # Keep CodecID for compatibility
      "CodecID" => audio_codec,
      "Channels" => to_string(media_info["audioChannels"] || 2),
      "Format_Commercial_IfAny" => CodecMapper.format_commercial_if_any(audio_codec)
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
end
