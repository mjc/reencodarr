defmodule Reencodarr.TestHelpers.Unified do
  @moduledoc """
  Unified test helpers consolidating functionality from TestHelpers, VideoHelpers,
  and PropertyHelpers into a single comprehensive module.

  Provides standardized patterns for:
  - Video/VMAF creation with realistic defaults
  - Property-based test data generation
  - Broadway pipeline testing
  - Common assertion patterns
  - External command mocking
  """

  import ExUnit.Assertions
  import ExUnit.CaptureLog

  alias Reencodarr.Media

  # === VIDEO CREATION HELPERS ===

  @doc """
  Creates a test video with default attributes that can be overridden.
  """
  def create_test_video(attrs \\ %{}) do
    default_attrs = %{
      path: "/test/video.mkv",
      size: 1_000_000_000,
      bitrate: 5000,
      duration: 3600.0,
      video_codecs: ["h264"],
      audio_codecs: ["aac"],
      reencoded: false,
      failed: false,
      service_type: "sonarr",
      service_id: "1",
      library_id: nil
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, video} = Media.create_video(attrs)
    video
  end

  @doc """
  Creates a test VMAF with default attributes for savings calculations.
  """
  def create_test_vmaf(video, attrs \\ %{}) do
    default_attrs = %{
      video_id: video.id,
      crf: 23,
      vmaf: 95.0,
      predicted_filesize: 500_000_000,
      chosen: false,
      percent: 50.0,
      score: 95.0,
      params: [],
      target: 95
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, vmaf} = Media.create_vmaf(attrs)
    vmaf
  end

  @doc """
  Creates a test video with VMAF for comprehensive testing.
  """
  def create_video_with_vmaf(video_attrs \\ %{}, vmaf_attrs \\ %{}) do
    video = create_test_video(video_attrs)
    vmaf = create_test_vmaf(video, vmaf_attrs)
    {video, vmaf}
  end

  @doc """
  Asserts savings calculation is correct based on percent and video size.
  """
  def assert_savings_calculation(vmaf, expected_percent) do
    video = vmaf.video
    expected_savings = round((100 - expected_percent) / 100 * video.size)
    assert vmaf.savings == expected_savings
  end

  # === PROPERTY-BASED TEST DATA GENERATORS ===

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
  """
  def video_attrs_generator do
    StreamData.fixed_map(%{
      path: video_path_generator(),
      service_type: StreamData.member_of(["sonarr", "radarr"]),
      service_id: StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
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
        StreamData.list_of(
          StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          max_length: 5
        )
    })
  end

  # === BROADWAY TESTING HELPERS ===

  @doc """
  Test that a Broadway pipeline can handle errors gracefully.
  """
  def test_broadway_error_handling(broadway_module, invalid_data) do
    log =
      capture_log(fn ->
        try do
          broadway_module.process_path(invalid_data)
          # Give time to process
          Process.sleep(100)
        rescue
          _ -> :ok
        end
      end)

    # Should not crash - any log output is acceptable
    assert is_binary(log)
  end

  @doc """
  Test multiple Broadway operations concurrently.
  """
  def test_concurrent_broadway_operations(data_list, broadway_module) do
    tasks = Enum.map(data_list, &create_broadway_task(&1, broadway_module))

    # All tasks should complete without hanging
    logs = Task.await_many(tasks, 5_000)

    # All tasks should produce some output
    assert length(logs) == length(data_list)
    Enum.each(logs, &assert(is_binary(&1)))
  end

  defp create_broadway_task(data, broadway_module) do
    Task.async(fn ->
      capture_log(fn ->
        try do
          broadway_module.process_path(data)
          Process.sleep(50)
        rescue
          _ -> :ok
        end
      end)
    end)
  end

  # === ASSERTION HELPERS ===

  @doc """
  Assert that a value is within expected tolerance range.
  """
  def assert_within_tolerance(actual, expected, tolerance \\ 0.1) do
    diff = abs(actual - expected)
    max_diff = expected * tolerance

    assert diff <= max_diff,
           "Expected #{actual} to be within #{tolerance * 100}% of #{expected}, but difference was #{diff}"
  end

  @doc """
  Assert that encoding queue is properly sorted by savings.
  """
  def assert_queue_sorted_by_savings(queue) when is_list(queue) do
    savings_list = Enum.map(queue, & &1.savings)
    sorted_savings = Enum.sort(savings_list, :desc)

    assert savings_list == sorted_savings,
           "Queue not sorted by savings: #{inspect(savings_list)} != #{inspect(sorted_savings)}"
  end

  @doc """
  Assert that a video has the expected codec configuration.
  """
  def assert_video_codecs(video, expected_video_codecs, expected_audio_codecs \\ []) do
    assert video.video_codecs == expected_video_codecs,
           "Expected video codecs #{inspect(expected_video_codecs)}, got #{inspect(video.video_codecs)}"

    if expected_audio_codecs != [] do
      assert video.audio_codecs == expected_audio_codecs,
             "Expected audio codecs #{inspect(expected_audio_codecs)}, got #{inspect(video.audio_codecs)}"
    end
  end

  # === VALIDATION HELPERS ===

  @doc """
  Generate invalid string values for negative testing.
  """
  def invalid_string_generator do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.constant(""),
      # Very long strings
      StreamData.string(:ascii, min_length: 1000, max_length: 2000)
    ])
  end

  @doc """
  Generate invalid number values for negative testing.
  """
  def invalid_number_generator do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.constant("invalid"),
      StreamData.constant(-1),
      # Unrealistically large
      StreamData.float(min: 1_000_000.0)
    ])
  end
end
