defmodule Reencodarr.Fixtures do
  @moduledoc """
  Consolidated test fixtures and database helpers for the Reencodarr test suite.

  This module provides a unified interface for creating test data with safe,
  anonymized content that doesn't reference real media files or show names.

  ## Usage

      # Import all fixtures
      import Reencodarr.Fixtures

      # Create test data
      video = video_fixture()
      video_with_vmaf = video_with_vmaf_fixture()
      encoding_scenario = encoding_scenario_fixture()
  """

  alias Reencodarr.Media

  # === SAFE TEST CONSTANTS ===

  @test_show_names [
    "Test Show Alpha",
    "Sample Series Beta",
    "Demo Program Gamma",
    "Mock Show Delta",
    "Example Series Epsilon"
  ]

  @test_movie_names [
    "Test Movie Alpha",
    "Sample Film Beta",
    "Demo Movie Gamma",
    "Mock Film Delta",
    "Example Movie Epsilon"
  ]

  @test_extensions [".mkv", ".mp4", ".avi", ".mov", ".webm", ".ts"]

  # === VIDEO FIXTURES ===

  @doc """
  Creates a video with safe test attributes.

  ## Examples

      video = video_fixture()
      video = video_fixture(%{bitrate: 5_000_000, height: 1080})
  """
  def video_fixture(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      path: "/test/videos/sample_video_#{unique_id}.mkv",
      bitrate: 3_500_000,
      size: 2_147_483_648, # 2GB
      height: 1080,
      width: 1920,
      video_codecs: ["h264"],
      audio_codecs: ["aac"],
      max_audio_channels: 6,
      atmos: false,
      hdr: nil,
      reencoded: false,
      failed: false,
      service_id: "#{unique_id}",
      service_type: :sonarr
    }

    attrs = Map.merge(defaults, attrs)

    {:ok, video} = Media.create_video(attrs)
    video
  end

  @doc """
  Creates a video with VMAF data for CRF search scenarios.
  """
  def video_with_vmaf_fixture(video_attrs \\ %{}, vmaf_attrs \\ %{}) do
    video = video_fixture(video_attrs)
    vmaf = vmaf_fixture(Map.merge(%{video_id: video.id}, vmaf_attrs))
    {video, vmaf}
  end

  @doc """
  Creates multiple videos with incrementing identifiers.
  """
  def videos_fixture(count, base_attrs \\ %{}) do
    Enum.map(1..count, fn i ->
      unique_id = System.unique_integer([:positive])
      attrs = Map.put(base_attrs, :path, "/test/videos/series_video_#{i}_#{unique_id}.mkv")
      video_fixture(attrs)
    end)
  end

  @doc """
  Creates a video suitable for encoding tests.
  """
  def encodable_video_fixture(attrs \\ %{}) do
    defaults = %{
      video_codec: "h264",
      bitrate: 10_000_000,
      # 5GB
      file_size: 5_368_709_120,
      height: 1080,
      reencoded: false,
      failed: false
    }

    video_fixture(Map.merge(defaults, attrs))
  end

  @doc """
  Creates a high bitrate video for savings calculations.
  """
  def high_bitrate_video_fixture(attrs \\ %{}) do
    defaults = %{
      bitrate: 15_000_000,
      # 8GB
      file_size: 8_589_934_592,
      video_codec: "h264"
    }

    video_fixture(Map.merge(defaults, attrs))
  end

  @doc """
  Creates an HDR video for HDR-specific tests.
  """
  def hdr_video_fixture(attrs \\ %{}) do
    defaults = %{
      hdr: "HDR10",
      height: 2160,
      width: 3840,
      bitrate: 20_000_000
    }

    video_fixture(Map.merge(defaults, attrs))
  end

  @doc """
  Creates a failed video for error handling tests.
  """
  def failed_video_fixture(attrs \\ %{}) do
    video_fixture(Map.merge(%{failed: true}, attrs))
  end

  @doc """
  Creates a reencoded video for completion scenarios.
  """
  def reencoded_video_fixture(attrs \\ %{}) do
    video_fixture(Map.merge(%{reencoded: true, video_codec: "av1"}, attrs))
  end

  # === STRUCT-BASED VIDEO CREATION ===

  @doc """
  Creates a test video struct (not persisted) with consistent defaults.

  This is useful for tests that need video structs without database interaction.
  """
  def build_video_struct(overrides \\ %{}) do
    defaults = %{
      atmos: false,
      max_audio_channels: 6,
      audio_codecs: ["A_EAC3"],
      video_codec: "V_MPEGH/ISO/HEVC",
      height: 1080,
      width: 1920,
      hdr: nil,
      file_size: 1_000_000_000,
      bitrate: 5_000_000,
      duration: 3600.0,
      path: unique_video_path(),
      reencoded: false,
      failed: false,
      service_type: "sonarr",
      service_id: "1",
      library_id: nil
    }

    struct(Reencodarr.Media.Video, Map.merge(defaults, overrides))
  end

  @doc """
  Creates a test video struct with HDR characteristics.
  """
  def build_hdr_video_struct(overrides \\ %{}) do
    build_video_struct(Map.merge(%{hdr: "HDR10", height: 2160, width: 3840}, overrides))
  end

  @doc """
  Creates a test video struct with Opus audio codec.
  """
  def build_opus_video_struct(overrides \\ %{}) do
    build_video_struct(Map.merge(%{audio_codecs: ["A_OPUS"]}, overrides))
  end

  @doc """
  Creates a test video struct with Atmos audio.
  """
  def build_atmos_video_struct(overrides \\ %{}) do
    build_video_struct(Map.merge(%{atmos: true}, overrides))
  end

  @doc """
  Creates a test video struct with minimal attributes for quick testing.
  """
  def build_minimal_video_struct(path \\ nil) do
    build_video_struct(%{
      path: path || unique_video_path(),
      file_size: 100_000_000,
      max_audio_channels: 2,
      audio_codecs: ["AAC"]
    })
  end

  # === VMAF FIXTURES ===

  @doc """
  Creates VMAF test data for a video.
  """
  def vmaf_fixture(attrs \\ %{}) do
    video =
      case Map.get(attrs, :video_id) do
        nil ->
          video = video_fixture()
          Map.put(attrs, :video_id, video.id)

        _ ->
          attrs
      end

    defaults = %{
      crf: 28,
      vmaf: 95.5,
      size_mb: 1024,
      percent_original_size: 75.0
    }

    vmaf_attrs = Map.merge(defaults, video)
    {:ok, vmaf} = Media.create_vmaf(vmaf_attrs)
    vmaf
  end

  @doc """
  Creates multiple VMAF entries for a video across different CRF values.
  """
  def vmaf_series_fixture(video, crf_range \\ [24, 26, 28, 30, 32]) do
    Enum.map(crf_range, fn crf ->
      vmaf_fixture(%{
        video_id: video.id,
        crf: crf,
        # Decreasing VMAF with higher CRF
        vmaf: 100.0 - (crf - 20) * 1.5,
        # Decreasing size with higher CRF
        size_mb: 2000 - (crf - 20) * 100
      })
    end)
  end

  # === LIBRARY FIXTURES ===

  @doc """
  Creates a library for organizing videos.
  """
  def library_fixture(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      name: "Test Library #{unique_id}",
      path: "/test/libraries/library_#{unique_id}",
      service_type: :sonarr
    }

    library_attrs = Map.merge(defaults, attrs)
    {:ok, library} = Media.create_library(library_attrs)
    library
  end

  # === ENCODING SCENARIOS ===

  @doc """
  Creates a complete encoding scenario with video and VMAF data.
  """
  def encoding_scenario_fixture(video_attrs \\ %{}, vmaf_attrs \\ %{}) do
    video = encodable_video_fixture(video_attrs)
    vmaf = vmaf_fixture(Map.merge(%{video_id: video.id}, vmaf_attrs))
    {video, vmaf}
  end

  @doc """
  Creates a scenario suitable for CRF search testing.
  """
  def crf_search_scenario_fixture(attrs \\ %{}) do
    video =
      video_fixture(
        Map.merge(
          %{
            video_codec: "h264",
            bitrate: 8_000_000,
            reencoded: false,
            failed: false
          },
          attrs
        )
      )

    # Create VMAF series to simulate CRF search results
    vmafs = vmaf_series_fixture(video)

    {video, vmafs}
  end

  # === PATH GENERATORS ===

  @doc """
  Generates a safe, unique video path for testing.
  """
  def unique_video_path(extension \\ ".mkv") do
    unique_id = System.unique_integer([:positive])
    timestamp = :os.system_time(:millisecond)
    "/test/videos/sample_#{unique_id}_#{timestamp}#{extension}"
  end

  @doc """
  Generates a safe show episode filename.
  """
  def sample_episode_path(show_name \\ nil, season \\ 1, episode \\ 1) do
    show = show_name || Enum.random(@test_show_names)
    unique_id = System.unique_integer([:positive])

    "/test/shows/#{show}_#{unique_id} - S#{String.pad_leading("#{season}", 2, "0")}E#{String.pad_leading("#{episode}", 2, "0")}.mkv"
  end

  @doc """
  Generates a safe movie filename.
  """
  def sample_movie_path(movie_name \\ nil) do
    movie = movie_name || Enum.random(@test_movie_names)
    unique_id = System.unique_integer([:positive])
    extension = Enum.random(@test_extensions)
    "/test/movies/#{movie}_#{unique_id}#{extension}"
  end

  # === TEMPORARY FILES ===

  @doc """
  Creates temporary test files with automatic cleanup.
  """
  def with_temp_files(count, content \\ "fake video content", extension \\ ".mkv", fun) do
    files =
      Enum.map(1..count, fn i ->
        file_path =
          Path.join(System.tmp_dir!(), "test_video_#{i}_#{:rand.uniform(10000)}#{extension}")

        File.write!(file_path, content)
        file_path
      end)

    try do
      fun.(files)
    after
      Enum.each(files, &File.rm/1)
    end
  end

  @doc """
  Creates a single temporary test file with automatic cleanup.
  """
  def with_temp_file(content \\ "fake video content", extension \\ ".mkv", fun) do
    with_temp_files(1, content, extension, fn [file] -> fun.(file) end)
  end

  # === STREAMING DATA GENERATORS (for property-based tests) ===

  @doc """
  StreamData generator for video paths.
  """
  def video_path_generator do
    StreamData.bind(
      StreamData.member_of(@test_extensions),
      fn ext ->
        StreamData.bind(StreamData.positive_integer(), fn id ->
          StreamData.constant("/test/generated/video_#{id}#{ext}")
        end)
      end
    )
  end

  @doc """
  StreamData generator for video attributes suitable for property-based testing.
  """
  def video_attrs_generator do
    StreamData.fixed_map(%{
      path: video_path_generator(),
      bitrate: StreamData.integer(1_000_000..50_000_000),
      file_size: StreamData.integer(100_000_000..10_000_000_000),
      height: StreamData.member_of([480, 720, 1080, 2160]),
      width: StreamData.member_of([640, 854, 1280, 1920, 3840]),
      video_codec: StreamData.member_of(["h264", "h265", "av1"]),
      audio_codecs:
        StreamData.list_of(StreamData.member_of(["aac", "ac3", "eac3", "dts"]),
          min_length: 1,
          max_length: 3
        ),
      max_audio_channels: StreamData.integer(1..8),
      atmos: StreamData.boolean(),
      hdr:
        StreamData.one_of([
          StreamData.constant(nil),
          StreamData.member_of(["HDR10", "DV", "HLG"])
        ])
    })
  end
end
