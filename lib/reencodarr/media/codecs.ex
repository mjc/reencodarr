defmodule Reencodarr.Media.Codecs do
  @moduledoc """
  Comprehensive codec processing utilities for Reencodarr.

  Consolidates all codec-related functionality including:
  - Codec ID mapping and normalization
  - Channel mapping and audio track analysis
  - Codec classification (video/audio, HDR, lossless, etc.)
  - Commercial format detection (Atmos, etc.)

  Delegates commercial format detection to `Reencodarr.Media.CodecMapper`
  for consistency with other modules.
  """

  alias Reencodarr.Media.CodecMapper

  @type codec_list :: [String.t()]
  @type codec_input :: String.t() | codec_list() | nil

  # === Codec Processing Functions ===

  @doc """
  Processes and normalizes codec information from various input formats.

  ## Examples

      iex> Codecs.process_codec_list("h264")
      ["H.264"]

      iex> Codecs.process_codec_list(["h264", "aac"])
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
  Normalizes a single codec name using commercial format mapping.
  """
  @spec normalize_codec(String.t()) :: String.t()
  def normalize_codec(codec) when is_binary(codec) do
    CodecMapper.format_commercial_if_any(codec)
  end

  @doc """
  Maps codec identifiers to standardized internal format.
  """
  @spec map_codec_id(String.t() | nil) :: String.t() | integer() | atom()
  def map_codec_id(codec) do
    CodecMapper.map_codec_id(codec)
  end

  # === Codec Detection Functions ===

  @doc """
  Checks if any codec in the list matches the given pattern (case-insensitive).

  ## Examples

      iex> Codecs.contains_codec?(["H.264", "AAC"], "h264")
      true

      iex> Codecs.contains_codec?(["H.264", "AAC"], "av1")
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
  Checks if the video codec list contains AV1.
  """
  @spec has_av1_codec?(codec_list() | nil) :: boolean()
  def has_av1_codec?(nil), do: false
  def has_av1_codec?(video_codecs), do: "V_AV1" in video_codecs || "AV1" in video_codecs

  @doc """
  Checks if the audio codec list contains Opus.
  """
  @spec has_opus_audio?(codec_list()) :: boolean()
  def has_opus_audio?(audio_codecs) when is_list(audio_codecs) do
    contains_codec?(audio_codecs, "opus")
  end

  @doc """
  Checks if MediaInfo data indicates Opus audio in any track.
  """
  @spec has_opus_audio_in_mediainfo?(map()) :: boolean()
  def has_opus_audio_in_mediainfo?(mediainfo) do
    tracks = get_in(mediainfo, ["media", "track"])

    case tracks do
      nil -> false
      tracks when is_list(tracks) -> Enum.any?(tracks, &audio_track_is_opus?/1)
      track when is_map(track) -> audio_track_is_opus?(track)
      _ -> false
    end
  end

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

  # === Codec Filtering Functions ===

  @doc """
  Extracts the primary video codec from a list of codecs.
  """
  @spec primary_video_codec(codec_list()) :: String.t() | nil
  def primary_video_codec([]), do: nil
  def primary_video_codec([primary | _]), do: primary

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

  # === Channel Mapping Functions ===

  @doc """
  Maps channel layout strings to channel counts.
  """
  @spec map_channels(String.t() | float() | integer()) :: integer()
  def map_channels(channel) do
    CodecMapper.map_channels(channel)
  end

  @doc """
  Maps channels with additional context from audio track data.

  This function provides more intelligent channel mapping by considering
  the audio codec and format when determining the actual channel count.
  """
  @spec map_channels_with_context(String.t() | float() | integer(), map()) :: integer()
  def map_channels_with_context(channel, audio_track \\ %{}) do
    CodecMapper.map_channels_with_context(channel, audio_track)
  end

  # === Private Helper Functions ===

  @spec audio_track_is_opus?(map()) :: boolean()
  defp audio_track_is_opus?(%{"@type" => "Audio", "Format" => "Opus"}), do: true
  defp audio_track_is_opus?(%{"@type" => "Audio", "CodecID" => "A_OPUS"}), do: true
  defp audio_track_is_opus?(_), do: false
end
