defmodule Reencodarr.Media.MediaInfo do
  @moduledoc """
  Logic for converting between VideoFileInfo structs and mediainfo maps, and extracting params for Ecto changesets.
  """
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Media.{CodecMapper, VideoFileInfo}

  # === MediaInfo Track Extraction Functions ===

  @doc """
  Gets an integer value from MediaInfo track data.
  """
  @spec get_int(map(), String.t(), String.t()) :: integer()
  def get_int(mediainfo, track_type, key) do
    case get_track(mediainfo, track_type) do
      nil ->
        0

      track ->
        track
        |> Map.get(key, "0")
        |> to_string()
        |> Parsers.parse_int(0)
    end
  end

  @doc """
  Gets a string value from MediaInfo track data.
  """
  @spec get_str(map(), String.t(), String.t()) :: String.t()
  def get_str(mediainfo, track_type, key) do
    case get_track(mediainfo, track_type) do
      nil ->
        ""

      track ->
        track
        |> Map.get(key, "")
        |> to_string()
    end
  end

  @doc """
  Gets a single track of specified type from MediaInfo data.
  """
  @spec get_track(map() | nil, String.t()) :: map() | nil
  def get_track(nil, _type), do: nil
  def get_track(%{"media" => nil}, _type), do: nil
  def get_track(%{"media" => %{"track" => nil}}, _type), do: nil
  def get_track(%{"media" => %{"track" => []}}, _type), do: nil

  def get_track(%{"media" => %{"track" => tracks}}, type) when is_list(tracks) do
    Enum.find(tracks, &(&1["@type"] == type))
  end

  def get_track(%{"media" => %{"track" => track}}, type) when is_map(track) do
    if track["@type"] == type, do: track, else: nil
  end

  def get_track(_mediainfo, _type), do: nil

  @doc """
  Gets all tracks of specified type from MediaInfo data.
  """
  @spec get_tracks(map() | nil, String.t()) :: [map()]
  def get_tracks(nil, _type), do: []
  def get_tracks(%{"media" => nil}, _type), do: []
  def get_tracks(%{"media" => %{"track" => nil}}, _type), do: []
  def get_tracks(%{"media" => %{"track" => []}}, _type), do: []

  def get_tracks(%{"media" => %{"track" => tracks}}, type) when is_list(tracks) do
    Enum.filter(tracks, &(&1["@type"] == type))
  end

  def get_tracks(%{"media" => %{"track" => track}}, type) when is_map(track) do
    if track["@type"] == type, do: [track], else: []
  end

  def get_tracks(_mediainfo, _type), do: []

  @doc """
  Checks if audio tracks contain Atmos encoding.
  """
  @spec has_atmos?(list()) :: boolean
  def has_atmos?(audio_tracks) when is_list(audio_tracks) do
    Enum.any?(audio_tracks, fn t ->
      String.contains?(Map.get(t, "Format_AdditionalFeatures", ""), "JOC") or
        String.contains?(Map.get(t, "Format_Commercial_IfAny", ""), "Atmos")
    end)
  end

  @doc """
  Gets the maximum number of audio channels across all tracks.
  """
  @spec max_audio_channels(list()) :: integer()
  def max_audio_channels(audio_tracks) when is_list(audio_tracks) do
    audio_tracks
    |> Enum.map(&get_channel_count_from_track/1)
    |> Enum.max(fn -> 0 end)
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
  Parse HDR information from a map containing HDR_Format field.
  """
  @spec parse_hdr_from_map(map()) :: String.t() | nil
  def parse_hdr_from_map(%{"HDR_Format" => hdr_format}) do
    parse_hdr([hdr_format])
  end

  def parse_hdr_from_map(_), do: nil

  @doc """
  Check if an audio format contains Atmos.
  """
  @spec has_atmos_format?(String.t() | nil) :: boolean()
  def has_atmos_format?(nil), do: false

  def has_atmos_format?(format) when is_binary(format) do
    String.contains?(format, "Atmos")
  end

  def has_atmos_format?(_), do: false

  # === Main Conversion Functions ===

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

  def to_video_params(mediainfo, path) do
    require Logger

    tracks = extract_tracks_safely(mediainfo, path)
    {general, video_tracks, audio_tracks} = extract_track_types(tracks, mediainfo)
    video_codecs = extract_video_codecs(video_tracks, path, mediainfo)

    build_video_params(general, video_tracks, audio_tracks, video_codecs, mediainfo, path)
  end

  defp extract_tracks_safely(mediainfo, path) do
    require Logger

    case mediainfo do
      # Handle standard MediaInfo structure
      %{"media" => %{"track" => tracks}} when is_list(tracks) ->
        tracks

      # Handle single track as a map
      %{"media" => %{"track" => track}} when is_map(track) ->
        [track]

      %{"media" => nil} ->
        []

      nil ->
        []

      _ ->
        # Log unexpected structure but don't crash
        Logger.warning(
          "Unexpected mediainfo structure for #{path}: #{inspect(mediainfo, pretty: true, limit: 1000)}"
        )

        []
    end
  end

  defp extract_track_types(tracks, _mediainfo) do
    general = Enum.find(tracks, &(&1["@type"] == "General")) || %{}
    video_tracks = Enum.filter(tracks, &(&1["@type"] == "Video"))
    audio_tracks = Enum.filter(tracks, &(&1["@type"] == "Audio"))

    {general, video_tracks, audio_tracks}
  end

  defp extract_video_codecs(video_tracks, path, mediainfo) do
    require Logger

    video_codecs = Enum.map(video_tracks, &Map.get(&1, "CodecID"))

    validate_video_codecs(video_codecs, video_tracks, path, mediainfo)
  end

  defp validate_video_codecs(video_codecs, video_tracks, path, mediainfo) do
    require Logger

    # Log structure in case of issues
    if Enum.empty?(video_tracks) do
      Logger.warning(
        "No video tracks found for #{path}: #{inspect(mediainfo, pretty: true, limit: 1000)}"
      )

      Logger.warning("video_codecs will be: #{inspect(video_codecs)}")
    end

    # Additional debugging for video_codecs
    if video_codecs == nil do
      Logger.error("❌ CRITICAL: video_codecs extracted as nil!")
      Logger.error("video_tracks: #{inspect(video_tracks)}")
      Logger.error("Full mediainfo: #{inspect(mediainfo, pretty: true, limit: :infinity)}")
      raise "video_codecs is nil after extraction - this indicates a bug"
    end

    video_codecs
  end

  defp build_video_params(general, video_tracks, audio_tracks, video_codecs, _mediainfo, path) do
    last_video = List.last(video_tracks)

    %{
      audio_codecs: Enum.map(audio_tracks, &Map.get(&1, "CodecID")),
      audio_count: Parsers.parse_int(general["AudioCount"], 0),
      atmos: has_atmos?(audio_tracks),
      bitrate: Parsers.parse_int(general["OverallBitRate"], 0),
      duration: Parsers.parse_float(general["Duration"], 0.0),
      frame_rate: Parsers.parse_float(last_video && Map.get(last_video, "FrameRate"), 0.0),
      hdr: parse_hdr_from_video(last_video),
      height: Parsers.parse_int(last_video && Map.get(last_video, "Height"), 0),
      max_audio_channels: max_audio_channels(audio_tracks),
      size: Parsers.parse_int(general["FileSize"], 0),
      text_codecs: [],
      text_count: Parsers.parse_int(general["TextCount"], 0),
      video_codecs: video_codecs,
      video_count: Parsers.parse_int(general["VideoCount"], 0),
      width: Parsers.parse_int(last_video && Map.get(last_video, "Width"), 0),
      reencoded: reencoded?(video_codecs, audio_tracks, general, last_video),
      title: Map.get(general, "Title") || Path.basename(path)
    }
  end

  def reencoded?(video_codecs, audio_tracks, general, video_track),
    do:
      CodecMapper.has_av1_codec?(video_codecs) or
        has_opus_audio_tracks?(audio_tracks) or
        low_bitrate_1080p?(video_codecs, general, video_track) or
        has_low_resolution_hevc?(video_codecs, video_track)

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

  # === Private Helper Functions ===

  # Check if audio tracks contain Opus
  defp has_opus_audio_tracks?(audio_tracks) when is_list(audio_tracks) do
    Enum.any?(audio_tracks, fn track ->
      Map.get(track, "Format") == "Opus" or Map.get(track, "CodecID") == "A_OPUS"
    end)
  end

  defp has_opus_audio_tracks?(_), do: false

  # Check for low bitrate 1080p content
  defp low_bitrate_1080p?(video_codecs, general, video_track) do
    "V_MPEGH/ISO/HEVC" in video_codecs and
      Parsers.parse_int(video_track && Map.get(video_track, "Width"), 0) == 1920 and
      Parsers.parse_int(general["OverallBitRate"], 0) < 20_000_000
  end

  # Check for low resolution HEVC content
  defp has_low_resolution_hevc?(video_codecs, video_track) do
    "V_MPEGH/ISO/HEVC" in video_codecs and
      Parsers.parse_int(video_track && Map.get(video_track, "Height"), 0) < 720
  end

  # Helper function to better extract channel count from audio track
  defp get_channel_count_from_track(track) do
    # Try multiple MediaInfo field name variations (case-insensitive)
    channel_positions =
      get_field_case_insensitive(track, ["ChannelPositions", "Channel_s_", "ChannelLayout"])

    channel_layout =
      get_field_case_insensitive(track, ["ChannelLayout", "Channel_Layout", "Channels_Layout"])

    channels_string =
      get_field_case_insensitive(track, ["Channel(s)/String", "Channels/String", "ChannelString"])

    # Check if this is 5.1 surround by looking for LFE in channel positions
    case contains_lfe_or_surround?(channel_positions) or
           contains_lfe_or_surround?(channel_layout) or
           contains_lfe_or_surround?(channels_string) do
      true ->
        detect_surround_channel_count(channel_positions, channel_layout, channels_string)

      false ->
        Parsers.parse_int(Map.get(track, "Channels", "0"), 0)
    end
  end

  # Finds a key in map ignoring case
  defp get_field_case_insensitive(track, field_names) do
    Enum.find_value(field_names, "", &get_field_value(track, &1))
  end

  # Attempt direct map lookup or case-insensitive key match
  defp get_field_value(track, field_name) do
    Map.get(track, field_name) ||
      case Enum.find(track, fn {k, _v} ->
             String.downcase(to_string(k)) == String.downcase(field_name)
           end) do
        {_, v} -> v
        _ -> nil
      end
  end

  # Check if string contains LFE or surround sound indicators (case-insensitive)
  defp contains_lfe_or_surround?(str) when is_binary(str) do
    lower_str = String.downcase(str)

    String.contains?(lower_str, "lfe") or
      String.contains?(lower_str, "5.1") or
      String.contains?(lower_str, "7.1") or
      String.contains?(lower_str, "6.1") or
      String.contains?(lower_str, "surround")
  end

  defp contains_lfe_or_surround?(_), do: false

  # Detect channel count from surround sound indicators
  defp detect_surround_channel_count(channel_positions, channel_layout, channels_string) do
    combined = "#{channel_positions} #{channel_layout} #{channels_string}" |> String.downcase()

    # Patterns to counts in priority order
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
