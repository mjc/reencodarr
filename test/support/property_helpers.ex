defmodule Reencodarr.PropertyHelpers do
  @moduledoc """
  Property-based testing helpers for Reencodarr.

  Provides generators and property-based test utilities for more thorough testing
  of edge cases and data validation.
  """

  @doc """
  Generate valid video file paths with various extensions.
  """
  def video_path_generator do
    StreamData.bind(StreamData.string(:alphanumeric, min_length: 1, max_length: 100), fn name ->
      StreamData.bind(video_extension_generator(), fn ext ->
        StreamData.constant("/#{name}#{ext}")
      end)
    end)
  end

  @doc """
  Generate common video file extensions.
  """
  def video_extension_generator do
    StreamData.member_of([".mkv", ".mp4", ".avi", ".mov", ".webm", ".ts", ".m2ts"])
  end

  @doc """
  Generate realistic video bitrates (in bits per second).
  """
  def video_bitrate_generator do
    # Range from 500 Kbps to 100 Mbps
    StreamData.integer(500_000..100_000_000)
  end

  @doc """
  Generate realistic file sizes (in bytes).
  """
  def file_size_generator do
    # Range from 100MB to 50GB
    StreamData.integer(100_000_000..50_000_000_000)
  end

  @doc """
  Generate video resolutions commonly found in media files.
  """
  def video_resolution_generator do
    StreamData.member_of([
      # SD
      {720, 480},
      # 720p
      {1280, 720},
      # 1080p
      {1920, 1080},
      # 1440p
      {2560, 1440},
      # 4K
      {3840, 2160},
      # 8K
      {7680, 4320}
    ])
  end

  @doc """
  Generate CRF values in the typical encoding range.
  """
  def crf_generator do
    StreamData.integer(18..35)
  end

  @doc """
  Generate VMAF scores (0.0 to 100.0).
  """
  def vmaf_score_generator do
    StreamData.float(min: 0.0, max: 100.0)
  end

  @doc """
  Generate video codec names.
  """
  def video_codec_generator do
    StreamData.member_of(["h264", "hevc", "av01", "vp9", "vp8", "mpeg2", "mpeg4"])
  end

  @doc """
  Generate lists of audio codecs.
  """
  def audio_codecs_generator do
    codec = StreamData.member_of(["aac", "ac3", "dts", "truehd", "flac", "opus"])
    StreamData.list_of(codec, min_length: 1, max_length: 3)
  end

  @doc """
  Generate complete video attributes for testing.
  Only includes fields that can be directly set in the Video changeset.
  """
  def video_attrs_generator do
    StreamData.fixed_map(%{
      path: video_path_generator(),
      size: file_size_generator(),
      bitrate: video_bitrate_generator()
    })
  end

  @doc """
  Generate VMAF record attributes for a given video ID.
  """
  def vmaf_attrs_generator(video_id) do
    StreamData.fixed_map(%{
      video_id: StreamData.constant(video_id),
      crf: crf_generator(),
      score: vmaf_score_generator(),
      params:
        StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          max_length: 5
        )
    })
  end

  @doc """
  Generate invalid string values for negative testing.
  """
  def invalid_string_generator do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.constant(""),
      # very long strings
      StreamData.string(:ascii, min_length: 1000, max_length: 2000)
    ])
  end

  @doc """
  Generate invalid number values for negative testing.
  """
  def invalid_number_generator do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.constant(-1),
      StreamData.constant(0),
      StreamData.float(min: -1000.0, max: -0.1)
    ])
  end
end
