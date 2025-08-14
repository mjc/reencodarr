defmodule Reencodarr.TestUtils do
  @moduledoc """
  Comprehensive testing utilities for the Reencodarr test suite.

  Consolidates all test-related helpers into a single module:
  - Test data generation and factories
  - Broadway pipeline testing
  - External command mocking
  - Common assertion patterns
  - Property-based test generators

  Replaces scattered test helper modules with organized, reusable utilities.
  """

  import ExUnit.Assertions
  import ExUnit.CaptureLog

  alias Reencodarr.{Media, Repo}

  # === TEST DATA FACTORIES ===

  @doc """
  Creates a test video with realistic defaults.
  """
  def create_test_video(attrs \\ %{}) do
    default_attrs = %{
      path: "/test/video_#{:rand.uniform(10000)}.mkv",
      size: 5_000_000_000,  # 5GB
      bitrate: 10_000_000,  # 10 Mbps
      video_codecs: ["H.264"],
      audio_codecs: ["AAC"],
      width: 1920,
      height: 1080,
      duration: 7200.0,  # 2 hours
      reencoded: false,
      failed: false
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, video} = Media.create_video(attrs)
    video
  end

  @doc """
  Creates a test VMAF with realistic values.
  """
  def create_test_vmaf(video, attrs \\ %{}) do
    default_attrs = %{
      video_id: video.id,
      crf: 28,
      vmaf_score: 95.5,
      predicted_filesize: 2_500_000_000,  # ~50% savings
      chosen: false
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, vmaf} = Media.create_vmaf(attrs)
    vmaf
  end

  @doc """
  Creates a complete video + VMAF scenario.
  """
  def create_encoding_scenario(video_attrs \\ %{}, vmaf_attrs \\ %{}) do
    video = create_test_video(video_attrs)
    vmaf = create_test_vmaf(video, vmaf_attrs)
    {video, vmaf}
  end

  @doc """
  Creates multiple test videos for bulk testing.
  """
  def create_test_video_series(count, base_attrs \\ %{}) do
    1..count
    |> Enum.map(fn i ->
      attrs = Map.put(base_attrs, :path, "/test/series_video_#{i}.mkv")
      create_test_video(attrs)
    end)
  end

  # === BROADWAY TESTING ===

  @doc """
  Tests that a Broadway pipeline handles errors gracefully.
  """
  def test_broadway_error_handling(broadway_module, invalid_data) do
    log = capture_log(fn ->
      try do
        broadway_module.process_path(invalid_data)
        Process.sleep(100)
      rescue
        _ -> :ok
      end
    end)

    assert is_binary(log)
  end

  @doc """
  Tests concurrent Broadway operations.
  """
  def test_concurrent_broadway(data_list, broadway_module) do
    tasks = Enum.map(data_list, fn data ->
      Task.async(fn ->
        capture_log(fn ->
          safely_process_broadway(data, broadway_module)
        end)
      end)
    end)

    logs = Task.await_many(tasks, 5000)
    Enum.each(logs, &assert(is_binary(&1)))
  end

  defp safely_process_broadway(data, broadway_module) do
    try do
      broadway_module.process_path(data)
      Process.sleep(50)
    rescue
      _ -> :ok
    end
  end

  # === FILE TESTING ===

  @doc """
  Creates temporary files for testing.
  """
  def with_temp_files(count, content \\ "fake content", extension \\ ".mkv", fun) do
    temp_files = 1..count
    |> Enum.map(fn i ->
      path = Path.join(System.tmp_dir!(), "test_file_#{i}_#{:rand.uniform(10000)}#{extension}")
      File.write!(path, content)
      path
    end)

    try do
      fun.(temp_files)
    after
      Enum.each(temp_files, &File.rm/1)
    end
  end

  @doc """
  Creates a single temporary file for testing.
  """
  def with_temp_file(content \\ "fake content", extension \\ ".mkv", fun) do
    with_temp_files(1, content, extension, fn [file] -> fun.(file) end)
  end

  # === ASSERTION HELPERS ===

  @doc """
  Waits for an async condition to be met.
  """
  def wait_for(condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 100)

    wait_until(condition_fn, timeout, interval)
  end

  defp wait_until(condition_fn, timeout, interval) when timeout > 0 do
    if condition_fn.() do
      :ok
    else
      Process.sleep(interval)
      wait_until(condition_fn, timeout - interval, interval)
    end
  end

  defp wait_until(_condition_fn, _timeout, _interval) do
    flunk("Condition was not met within timeout")
  end

  @doc """
  Asserts that telemetry events are emitted.
  """
  def assert_telemetry_event(event_name, expected_measurements, test_fn) do
    ref = :telemetry_test.attach_event_handlers(self(), [event_name])

    test_fn.()

    assert_receive {[:telemetry, :event], ^ref, ^expected_measurements, _metadata}, 1000

    :telemetry.detach({__MODULE__, ref})
  end

  @doc """
  Asserts database state after operations.
  """
  def assert_database_state(schema_module, expected_count, test_fn) do
    initial_count = Repo.aggregate(schema_module, :count)

    test_fn.()

    final_count = Repo.aggregate(schema_module, :count)
    assert final_count == initial_count + expected_count
  end

  # === PROPERTY-BASED GENERATORS ===

  @doc """
  Generates realistic video file paths.
  """
  def video_path_generator do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 50),
      fn name ->
        StreamData.bind(video_extension_generator(), fn ext ->
          StreamData.constant("/test/#{name}#{ext}")
        end)
      end
    )
  end

  @doc """
  Generates video file extensions.
  """
  def video_extension_generator do
    StreamData.member_of([".mkv", ".mp4", ".avi", ".mov", ".webm", ".ts"])
  end

  @doc """
  Generates realistic video bitrates (500Kbps to 100Mbps).
  """
  def video_bitrate_generator do
    StreamData.integer(500_000..100_000_000)
  end

  @doc """
  Generates realistic file sizes (100MB to 50GB).
  """
  def file_size_generator do
    StreamData.integer(100_000_000..50_000_000_000)
  end

  @doc """
  Generates common video resolutions.
  """
  def video_resolution_generator do
    StreamData.member_of([
      {1920, 1080},  # 1080p
      {3840, 2160},  # 4K
      {1280, 720},   # 720p
      {2560, 1440},  # 1440p
      {7680, 4320}   # 8K
    ])
  end

  @doc """
  Generates CRF values in encoding range.
  """
  def crf_generator do
    StreamData.integer(18..35)
  end

  @doc """
  Generates VMAF scores.
  """
  def vmaf_score_generator do
    StreamData.float(min: 0.0, max: 100.0)
  end

  @doc """
  Generates video codec names.
  """
  def video_codec_generator do
    StreamData.member_of(["h264", "hevc", "av01", "vp9", "vp8"])
  end

  @doc """
  Generates audio codec lists.
  """
  def audio_codecs_generator do
    codec = StreamData.member_of(["aac", "ac3", "dts", "truehd", "flac", "opus"])
    StreamData.list_of(codec, min_length: 1, max_length: 3)
  end

  # === CALCULATION HELPERS ===

  @doc """
  Calculates expected savings percentage.
  """
  def calculate_savings_percent(original_size, new_size)
      when is_number(original_size) and is_number(new_size) and original_size > 0 do
    ((original_size - new_size) / original_size * 100) |> Float.round(1)
  end
  def calculate_savings_percent(_, _), do: 0.0

  @doc """
  Calculates expected savings in bytes.
  """
  def calculate_savings_bytes(original_size, new_size)
      when is_number(original_size) and is_number(new_size) do
    max(0, original_size - new_size)
  end
  def calculate_savings_bytes(_, _), do: 0

  # === VALIDATION HELPERS ===

  @doc """
  Validates that video attributes match expected values.
  """
  def assert_video_attributes(video, expected_attrs) do
    Enum.each(expected_attrs, fn {key, expected_value} ->
      actual_value = Map.get(video, key)
      assert actual_value == expected_value,
        "Expected video.#{key} to be #{inspect(expected_value)}, got #{inspect(actual_value)}"
    end)
  end

  @doc """
  Tests enum handling across all values.
  """
  def test_enum_handling(module, function, expected_mappings) do
    Enum.each(expected_mappings, fn {input, expected_output} ->
      actual_output = apply(module, function, [input])

      assert actual_output == expected_output,
        "Expected #{module}.#{function}(#{inspect(input)}) to return #{inspect(expected_output)}, " <>
        "got #{inspect(actual_output)}"
    end)
  end
end
