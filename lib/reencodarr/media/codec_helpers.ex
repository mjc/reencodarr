defmodule Reencodarr.Media.CodecHelpers do
  @moduledoc """
  Unified codec processing utilities for Reencodarr.

  Consolidates codec functionality from CodecHelper and CodecProcessor
  into a single comprehensive module.
  """

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
end
