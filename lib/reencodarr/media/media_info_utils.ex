defmodule Reencodarr.Media.MediaInfoUtils do
  @moduledoc """
  Consolidated MediaInfo processing utilities for Reencodarr.

  This module consolidates the functionality from MediaInfo, MediaInfoExtractor,
  and MediaInfoConverter into a single, comprehensive utility module.

  Handles:
  - MediaInfo JSON parsing and validation
  - Track extraction and processing
  - HDR detection and parsing
  - Audio format analysis (Atmos, channels)
  - Video parameter extraction
  - Legacy format conversion
  """

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Media.{CodecMapper, Codecs, MediaInfo, VideoFileInfo}

  @doc """
  Extracts all needed video parameters directly from MediaInfo JSON.

  Returns a flat map with all the fields we need, avoiding repeated track traversal.
  """
  @spec extract_video_params(map(), String.t()) :: map()
  def extract_video_params(mediainfo, path) do
    tracks = extract_tracks_safely(mediainfo, path)

    general = find_track(tracks, "General")
    video_track = find_track(tracks, "Video")
    audio_tracks = filter_tracks(tracks, "Audio")

    %{
      # Core video info
      width: get_int_field(video_track, "Width", 0),
      height: get_int_field(video_track, "Height", 0),
      frame_rate: get_float_field(video_track, "FrameRate", 0.0),
      duration: get_float_field(general, "Duration", 0.0),
      size: get_int_field(general, "FileSize", 0),
      bitrate: get_int_field(general, "OverallBitRate", 0),

      # Codecs
      video_codecs: [get_string_field(video_track, "CodecID", "")],
      audio_codecs: extract_audio_codecs_safely(audio_tracks, general),

      # Audio info - use actual count of audio tracks found to ensure consistency
      audio_count: length(audio_tracks),
      max_audio_channels: calculate_max_audio_channels(audio_tracks),
      atmos: detect_atmos(audio_tracks),

      # Text/subtitle info
      text_count: get_int_field(general, "TextCount", 0),
      text_codecs: [],

      # Video counts
      video_count: get_int_field(general, "VideoCount", 0),

      # HDR info
      hdr: MediaInfo.parse_hdr_from_video(video_track)
    }
  end

  @doc """
  Validates and processes MediaInfo JSON data.
  """
  @spec from_mediainfo_json(map()) :: {:ok, map()} | {:error, String.t()}
  def from_mediainfo_json(mediainfo) when is_map(mediainfo) do
    # Just pass through the mediainfo - this is a compatibility function
    # for any remaining legacy calls
    {:ok, mediainfo}
  end

  def from_mediainfo_json(_invalid_data) do
    {:error, "invalid mediainfo format"}
  end

  @doc """
  Converts VideoFileInfo struct to MediaInfo JSON format for legacy compatibility.
  """
  @spec from_video_file_info(VideoFileInfo.t()) :: map()
  def from_video_file_info(%VideoFileInfo{} = info) do
    {width, height} = parse_resolution(info.resolution)

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

  # === Private Helper Functions ===

  # Safely extract tracks from MediaInfo JSON with error handling
  defp extract_tracks_safely(mediainfo, path) do
    case get_in(mediainfo, ["media", "track"]) do
      tracks when is_list(tracks) ->
        tracks

      track when is_map(track) ->
        [track]

      nil ->
        require Logger
        Logger.warning("No tracks found in MediaInfo for #{path}")
        []

      other ->
        require Logger
        Logger.warning("Unexpected track format in MediaInfo for #{path}: #{inspect(other)}")
        []
    end
  end

  # Find the first track of a specific type
  defp find_track(tracks, type) when is_list(tracks) do
    Enum.find(tracks, %{}, fn track ->
      Map.get(track, "@type") == type
    end)
  end

  # Filter tracks by type
  defp filter_tracks(tracks, type) when is_list(tracks) do
    Enum.filter(tracks, fn track ->
      Map.get(track, "@type") == type
    end)
  end

  # Safe field extraction with defaults
  defp get_string_field(track, field, default) when is_map(track) do
    case Map.get(track, field) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp get_int_field(track, field, default) when is_map(track) do
    case Map.get(track, field) do
      value when is_integer(value) -> value
      value when is_binary(value) -> 
        case Integer.parse(value) do
          {int_value, ""} -> int_value
          _ -> default
        end
      value when is_float(value) -> round(value)
      _ -> default
    end
  end

  defp get_float_field(track, field, default) when is_map(track) do
    case Map.get(track, field) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1.0
      value when is_binary(value) -> 
        case Float.parse(value) do
          {float_value, ""} -> float_value
          _ -> default
        end
      _ -> default
    end
  end

  # Extract audio codecs with fallback and normalization
  defp extract_audio_codecs_safely(audio_tracks, general) do
    primary_codecs =
      audio_tracks
      |> Enum.map(fn track ->
        # Try multiple fields for codec detection
        codec =
          get_string_field(track, "CodecID", "") ||
            get_string_field(track, "Format", "") ||
            get_string_field(track, "Codec", "")

        if codec != "", do: codec, else: nil
      end)
      |> Enum.filter(&(!is_nil(&1)))

    # If no audio codecs found in tracks, try general track as fallback
    if primary_codecs == [] do
      fallback = get_string_field(general, "Audio_Codec_List", "")
      if fallback != "", do: [fallback], else: []
    else
      primary_codecs
    end
  end

  # Calculate the maximum audio channels across all tracks
  defp calculate_max_audio_channels(audio_tracks) do
    audio_tracks
    |> Enum.map(fn track ->
      channels = get_string_field(track, "Channels", "0")
      Codecs.map_channels_with_context(channels, track)
    end)
    |> Enum.max(fn -> 0 end)
  end

  # Detect Atmos from audio tracks
  defp detect_atmos(audio_tracks) do
    Enum.any?(audio_tracks, fn track ->
      commercial = get_string_field(track, "Format_Commercial_IfAny", "")
      codec = get_string_field(track, "CodecID", "")
      format = get_string_field(track, "Format", "")

      has_atmos_format?(commercial) or
        has_atmos_format?(codec) or
        has_atmos_format?(format)
    end)
  end

  # Parse resolution from VideoFileInfo format
  defp parse_resolution({width, height}) when is_integer(width) and is_integer(height) do
    {width, height}
  end

  defp parse_resolution(resolution) when is_binary(resolution) do
    case String.split(resolution, "x") do
      [width_str, height_str] ->
        # Use Integer.parse/1 to safely handle potentially invalid input
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
end
