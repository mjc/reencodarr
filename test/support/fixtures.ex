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
      # 2GB
      size: 2_147_483_648,
      height: 1080,
      width: 1920,
      video_codecs: ["h264"],
      audio_codecs: ["aac"],
      max_audio_channels: 6,
      atmos: false,
      hdr: nil,
      state: :needs_analysis,
      service_id: "#{unique_id}",
      service_type: :sonarr
    }

    attrs = Map.merge(defaults, attrs)

    case Media.upsert_video(attrs) do
      {:ok, video} -> video
      {:error, changeset} -> raise "Failed to create video fixture: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Creates a video with VMAF data for CRF search scenarios.
  """
  def video_fixture_with_result(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      path: "/test/sample_video#{unique_id}.mkv",
      bitrate: 5_000_000,
      size: 2_000_000_000,
      width: 1920,
      height: 1080,
      fps: 23.976,
      duration: 3600.0,
      video_codecs: ["h264"],
      audio_codecs: ["aac"],
      max_audio_channels: 6,
      atmos: false,
      hdr: nil,
      state: :needs_analysis,
      service_id: "#{unique_id}",
      service_type: :sonarr
    }

    attrs = Map.merge(defaults, attrs)
    Media.upsert_video(attrs)
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
      state: :needs_analysis
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
    video_fixture(Map.merge(%{state: :failed}, attrs))
  end

  @doc """
  Creates an encoded video for completion scenarios.
  """
  def encoded_video_fixture(attrs \\ %{}) do
    video_fixture(Map.merge(%{state: :encoded, video_codecs: ["AV1"]}, attrs))
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
      state: :needs_analysis,
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
    attrs =
      case Map.get(attrs, :video_id) do
        nil ->
          video = video_fixture()
          Map.put(attrs, :video_id, video.id)

        _ ->
          attrs
      end

    defaults = %{
      crf: 28.0,
      score: 95.5,
      params: ["--preset", "medium"],
      predicted_size: 1500.0
    }

    vmaf_attrs = Map.merge(defaults, attrs)
    {:ok, vmaf} = Media.create_vmaf(vmaf_attrs)
    vmaf
  end

  @doc """
  Creates multiple VMAF entries for a video across different CRF values.
  """
  def vmaf_series_fixture(video, crf_range \\ [24, 26, 28, 30, 32]) do
    Enum.map(crf_range, fn crf ->
      # Simulate decreasing quality with higher CRF
      score = 100.0 - (crf - 20) * 2.0

      vmaf_fixture(%{
        video_id: video.id,
        crf: crf,
        score: score
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

  @doc """
  Creates multiple libraries with common attributes.
  """
  def libraries_fixture(count, base_attrs \\ %{}) do
    1..count
    |> Enum.map(fn _i ->
      library_fixture(base_attrs)
    end)
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
            state: :needs_analysis
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

  # === CONVENIENCE VIDEO CREATORS ===

  @doc """
  Creates a standard test video with typical properties.
  """
  def create_test_video(attrs \\ %{}) do
    default_attrs = %{
      path: "/test/sample_video.mkv",
      bitrate: 8_000_000,
      size: 3_000_000_000,
      video_codecs: ["h264"],
      audio_codecs: ["aac"],
      state: :needs_analysis,
      width: 1920,
      height: 1080,
      fps: 23.976,
      duration: 7200.0,
      max_audio_channels: 6,
      atmos: false,
      hdr: nil
    }

    attrs = Map.merge(default_attrs, attrs)
    video_fixture(attrs)
  end

  @doc """
  Creates a test video that already has Opus audio (doesn't need audio transcoding).
  """
  def create_opus_video(attrs \\ %{}) do
    default_attrs = %{
      path: "/test/opus_video.mkv",
      bitrate: 6_000_000,
      size: 2_500_000_000,
      video_codecs: ["h264"],
      audio_codecs: ["A_OPUS"],
      state: :needs_analysis,
      width: 1920,
      height: 1080,
      fps: 23.976,
      duration: 7200.0,
      max_audio_channels: 6,
      atmos: false,
      hdr: nil
    }

    attrs = Map.merge(default_attrs, attrs)
    video_fixture(attrs)
  end

  @doc """
  Creates an HDR test video.
  """
  def create_hdr_video(attrs \\ %{}) do
    default_attrs = %{
      path: "/test/hdr_video.mkv",
      bitrate: 20_000_000,
      size: 8_000_000_000,
      video_codecs: ["h265"],
      audio_codecs: ["truehd"],
      state: :needs_analysis,
      width: 1920,
      height: 1080,
      fps: 23.976,
      duration: 7200.0,
      max_audio_channels: 8,
      atmos: true,
      hdr: "HDR10"
    }

    attrs = Map.merge(default_attrs, attrs)
    video_fixture(attrs)
  end

  @doc """
  Creates a 4K test video.
  """
  def create_4k_video(attrs \\ %{}) do
    default_attrs = %{
      path: "/test/4k_video.mkv",
      bitrate: 25_000_000,
      size: 12_000_000_000,
      video_codecs: ["h265"],
      audio_codecs: ["truehd"],
      state: :needs_analysis,
      width: 3840,
      height: 2160,
      fps: 23.976,
      duration: 7200.0,
      max_audio_channels: 8,
      atmos: true,
      hdr: nil
    }

    attrs = Map.merge(default_attrs, attrs)
    video_fixture(attrs)
  end

  # === FACTORY PATTERN SUPPORT ===
  # Migrated from MediaFixtures for builder-style test construction

  @doc """
  Starts building a video with factory pattern.

  ## Examples

      video = build_video(%{bitrate: 5_000_000})
        |> with_high_bitrate()
        |> as_encoded()
        |> create()
  """
  def build_video(attrs \\ %{}) do
    defaults = %{
      bitrate: 5_000_000,
      size: 2_000_000_000,
      state: :needs_analysis
    }

    Map.merge(defaults, attrs)
  end

  @doc """
  Sets high bitrate for factory building.
  """
  def with_high_bitrate(attrs, bitrate \\ 15_000_000) do
    Map.put(attrs, :bitrate, bitrate)
  end

  @doc """
  Sets path for factory building.
  """
  def with_path(attrs, path) do
    Map.put(attrs, :path, path)
  end

  @doc """
  Marks video as encoded for factory building.
  """
  def as_encoded(attrs) do
    Map.merge(attrs, %{state: :encoded, video_codecs: ["AV1"]})
  end

  @doc """
  Marks video as failed for factory building.
  """
  def as_failed(attrs) do
    Map.put(attrs, :state, :failed)
  end

  @doc """
  Creates the video with accumulated factory attributes.
  """
  def create(attrs) do
    video_fixture(attrs)
  end

  @doc """
  Creates optimal VMAF fixture for target score testing.
  """
  def optimal_vmaf_fixture(video, target_score \\ 95.0) do
    vmaf_fixture(%{
      video_id: video.id,
      crf: 28.0,
      score: target_score,
      predicted_size: video.size * 0.6
    })
  end

  @doc """
  Generates a unique library path.
  """
  def unique_library_path do
    unique_id = System.unique_integer([:positive])
    "/test/libraries/library_#{unique_id}"
  end
end
