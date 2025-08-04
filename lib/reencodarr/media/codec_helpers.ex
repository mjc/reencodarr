defmodule Reencodarr.Media.CodecHelpers do
  @moduledoc """
  Unified codec processing utilities for Reencodarr.

  Consolidates codec functionality from CodecHelper and CodecProcessor
  into a single comprehensive module.
  """

  alias Reencodarr.FormatHelpers
  alias Reencodarr.Media.CodecMapper

  @type codec_list :: [String.t()]
  @type codec_input :: String.t() | codec_list() | nil

  # === High-level Codec Operations ===

  @doc """
  Processes and normalizes codec information from various input formats.

  ## Examples

      iex> CodecHelpers.process_codec_list("h264")
      ["H.264"]

      iex> CodecHelpers.process_codec_list(["h264", "aac"])
      ["H.264", "AAC"]
  """
  @spec process_codec_list(codec_input()) :: codec_list()
  def process_codec_list(nil), do: []
  def process_codec_list([]), do: []

  def process_codec_list(codec) when is_binary(codec) do
    [normalize_codec(codec)]
  end

  def process_codec_list(codecs) when is_list(codecs) do
    codecs
    |> Enum.map(&normalize_codec/1)
    |> Enum.uniq()
  end

  @doc """
  Normalizes a single codec name using the CodecMapper.
  """
  @spec normalize_codec(String.t()) :: String.t()
  def normalize_codec(codec) when is_binary(codec) do
    CodecMapper.format_commercial_if_any(codec)
  end

  @doc """
  Checks if any codec in the list matches the given pattern (case-insensitive).

  ## Examples

      iex> CodecHelpers.contains_codec?(["H.264", "AAC"], "h264")
      true

      iex> CodecHelpers.contains_codec?(["H.264", "AAC"], "av1")
      false
  """
  @spec contains_codec?(codec_list(), String.t()) :: boolean()
  def contains_codec?(codec_list, pattern) when is_list(codec_list) and is_binary(pattern) do
    pattern_lower = String.downcase(pattern)

    Enum.any?(codec_list, fn codec ->
      String.downcase(codec) =~ pattern_lower
    end)
  end

  @doc """
  Extracts the primary video codec from a list of codecs.
  """
  @spec primary_video_codec(codec_list()) :: String.t() | nil
  def primary_video_codec([]), do: nil
  def primary_video_codec([primary | _]), do: primary

  @doc """
  Checks if the codec list indicates HDR content.
  """
  @spec hdr_content?(codec_list()) :: boolean()
  def hdr_content?(codec_list) when is_list(codec_list) do
    contains_codec?(codec_list, "hdr") or
      contains_codec?(codec_list, "dolby vision") or
      contains_codec?(codec_list, "hdr10")
  end

  @doc """
  Checks if the codec list indicates lossless audio content.
  """
  @spec lossless_audio?(codec_list()) :: boolean()
  def lossless_audio?(codec_list) when is_list(codec_list) do
    contains_codec?(codec_list, "flac") or
      contains_codec?(codec_list, "truehd") or
      contains_codec?(codec_list, "dts-hd") or
      contains_codec?(codec_list, "pcm")
  end

  @doc """
  Filters codec list to only include video codecs.
  """
  @spec video_codecs_only(codec_list()) :: codec_list()
  def video_codecs_only(codec_list) when is_list(codec_list) do
    video_codec_patterns = ["h264", "h265", "hevc", "av1", "vp9", "mpeg2", "mpeg4"]

    Enum.filter(codec_list, fn codec ->
      Enum.any?(video_codec_patterns, &contains_codec?([codec], &1))
    end)
  end

  @doc """
  Filters codec list to only include audio codecs.
  """
  @spec audio_codecs_only(codec_list()) :: codec_list()
  def audio_codecs_only(codec_list) when is_list(codec_list) do
    audio_codec_patterns = ["aac", "ac3", "eac3", "dts", "truehd", "flac", "opus", "mp3", "pcm"]

    Enum.filter(codec_list, fn codec ->
      Enum.any?(audio_codec_patterns, &contains_codec?([codec], &1))
    end)
  end

  # === MediaInfo Parsing Functions ===

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
        |> FormatHelpers.parse_int(0)
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

  # === Audio Channel Processing ===

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

  # === HDR Processing ===

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

  # === Subtitle Processing ===

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

  # === Private Helper Functions ===

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
        FormatHelpers.parse_int(Map.get(track, "Channels", "0"), 0)
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
