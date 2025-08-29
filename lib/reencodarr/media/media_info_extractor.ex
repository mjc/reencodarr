defmodule Reencodarr.Media.MediaInfoExtractor do
  @moduledoc """
  Simple, direct extraction of MediaInfo data to avoid complex track traversal.

  This replaces the complex get_track/get_int/get_str pattern with direct field extraction
  that happens once during JSON parsing, creating a flat structure for easy access.
  """

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Media.MediaInfo

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
      hdr: extract_hdr_info(video_track),

      # Title fallback
      title: get_string_field(general, "Title", Path.basename(path))
    }
  end

  # === Private Helper Functions ===

  defp extract_tracks_safely(mediainfo, path) do
    require Logger

    case mediainfo do
      %{"media" => %{"track" => tracks}} when is_list(tracks) ->
        tracks

      %{"media" => %{"track" => track}} when is_map(track) ->
        [track]

      %{"media" => nil} ->
        []

      nil ->
        []

      _ ->
        Logger.warning(
          "Unexpected mediainfo structure for #{path}: #{inspect(mediainfo, limit: 1000)}"
        )

        []
    end
  end

  defp find_track(tracks, type) do
    Enum.find(tracks, &(&1["@type"] == type))
  end

  defp filter_tracks(tracks, type) do
    Enum.filter(tracks, &(&1["@type"] == type))
  end

  defp get_int_field(nil, _key, default), do: default

  defp get_int_field(track, key, default) do
    case Map.get(track, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> Parsers.parse_int(value, default)
      _ -> default
    end
  end

  defp get_float_field(nil, _key, default), do: default

  defp get_float_field(track, key, default) do
    case Map.get(track, key) do
      value when is_float(value) -> value
      value when is_binary(value) -> Parsers.parse_float(value, default)
      _ -> default
    end
  end

  defp get_string_field(nil, _key, default), do: default

  defp get_string_field(track, key, default) do
    Map.get(track, key, default) |> to_string()
  end

  defp calculate_max_audio_channels(audio_tracks) do
    audio_tracks
    |> Enum.map(&get_channel_count_from_track/1)
    |> Enum.max(fn -> 0 end)
  end

  defp extract_audio_codecs_safely(audio_tracks, general) do
    codecs = Enum.map(audio_tracks, &get_string_field(&1, "CodecID", ""))

    # If no audio tracks found but General track indicates audio exists,
    # add a placeholder to prevent validation errors
    if Enum.empty?(codecs) and get_int_field(general, "AudioCount", 0) > 0 do
      ["unknown"]
    else
      codecs
    end
  end

  defp detect_atmos(audio_tracks) do
    Enum.any?(audio_tracks, fn track ->
      get_string_field(track, "Format_AdditionalFeatures", "") |> String.contains?("JOC") or
        get_string_field(track, "Format_Commercial_IfAny", "") |> String.contains?("Atmos")
    end)
  end

  defp extract_hdr_info(nil), do: nil

  defp extract_hdr_info(video_track) do
    MediaInfo.parse_hdr([
      get_string_field(video_track, "HDR_Format", ""),
      get_string_field(video_track, "HDR_Format_Compatibility", ""),
      get_string_field(video_track, "transfer_characteristics", "")
    ])
  end

  defp get_channel_count_from_track(track) do
    # Try multiple MediaInfo field name variations (case-insensitive)
    channel_positions = get_string_field(track, "ChannelPositions", "")
    channel_layout = get_string_field(track, "ChannelLayout", "")
    channels_string = get_string_field(track, "Channel(s)/String", "")

    # Check if this is 5.1 surround by looking for LFE in channel positions
    case contains_lfe_or_surround?(channel_positions) or
           contains_lfe_or_surround?(channel_layout) or
           contains_lfe_or_surround?(channels_string) do
      true ->
        detect_surround_channel_count(channel_positions, channel_layout, channels_string)

      false ->
        get_int_field(track, "Channels", 0)
    end
  end

  defp contains_lfe_or_surround?(str) when is_binary(str) do
    lower_str = String.downcase(str)

    String.contains?(lower_str, "lfe") or
      String.contains?(lower_str, "5.1") or
      String.contains?(lower_str, "7.1") or
      String.contains?(lower_str, "6.1") or
      String.contains?(lower_str, "surround")
  end

  defp contains_lfe_or_surround?(_), do: false

  defp detect_surround_channel_count(channel_positions, channel_layout, channels_string) do
    combined = "#{channel_positions} #{channel_layout} #{channels_string}" |> String.downcase()

    patterns = [
      {"9.1", 10},
      {"9.2", 11},
      {"8.1", 9},
      {"8.2", 10},
      {"7.1", 8},
      {"7.2", 9},
      {"6.1", 7},
      {"5.1", 6},
      {"4.1", 5},
      {"3.1", 4},
      {"2.1", 3},
      {"lfe", 6}
    ]

    Enum.find_value(patterns, fn {substr, count} ->
      if String.contains?(combined, substr), do: count, else: nil
    end) || 6
  end
end
