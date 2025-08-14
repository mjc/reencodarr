defmodule Reencodarr.TestPatterns do
  @moduledoc """
  Consolidated test patterns and helpers to eliminate duplication across test files.

  This module provides common patterns for:
  - Video creation with consistent defaults
  - Argument parsing and validation
  - Pattern matching helpers
  - Flag finding and validation utilities
  """

  import ExUnit.Assertions
  alias Reencodarr.Media

  # === VIDEO CREATION PATTERNS ===

  @doc """
  Creates a test video struct with consistent defaults across all tests.

  This replaces the numerous `create_test_video/1` functions duplicated
  across multiple test files.
  """
  def create_test_video(overrides \\ %{}) do
    defaults = %{
      atmos: false,
      max_audio_channels: 6,
      audio_codecs: ["A_EAC3"],
      video_codecs: ["V_MPEGH/ISO/HEVC"],
      height: 1080,
      width: 1920,
      hdr: nil,
      size: 1_000_000_000,
      bitrate: 5_000_000,
      duration: 3600.0,
      path: "/test/video.mkv",
      reencoded: false,
      failed: false,
      service_type: "sonarr",
      service_id: "1",
      library_id: nil
    }

    struct(Reencodarr.Media.Video, Map.merge(defaults, overrides))
  end

  @doc """
  Creates a test video with HDR characteristics.
  """
  def create_hdr_video(overrides \\ %{}) do
    create_test_video(Map.merge(%{hdr: "HDR10"}, overrides))
  end

  @doc """
  Creates a test video with Opus audio codec.
  """
  def create_opus_video(overrides \\ %{}) do
    create_test_video(Map.merge(%{audio_codecs: ["A_OPUS"]}, overrides))
  end

  @doc """
  Creates a test video with 4K resolution.
  """
  def create_4k_video(overrides \\ %{}) do
    create_test_video(Map.merge(%{height: 2160, width: 3840}, overrides))
  end

  @doc """
  Creates a test video with Atmos audio.
  """
  def create_atmos_video(overrides \\ %{}) do
    create_test_video(Map.merge(%{atmos: true}, overrides))
  end

  @doc """
  Creates a test video with minimal attributes for quick testing.
  """
  def create_minimal_video(path \\ "/test/minimal.mkv") do
    create_test_video(%{
      path: path,
      size: 100_000_000,
      max_audio_channels: 2,
      audio_codecs: ["AAC"]
    })
  end

  # === DATABASE VIDEO CREATION ===

  @doc """
  Creates a test video in the database with default attributes.
  """
  def create_database_video(attrs \\ %{}) do
    default_attrs = %{
      path: "/test/db_video.mkv",
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

  # === ARGUMENT PARSING HELPERS ===

  @doc """
  Finds all indices where a specific flag appears in an argument list.

  This replaces the duplicated `find_flag_indices/2` functions across tests.

  ## Examples

      iex> find_flag_indices(["--preset", "6", "--svt", "tune=0", "--preset", "4"], "--preset")
      [0, 4]
  """
  def find_flag_indices(args, flag) do
    args
    |> Enum.with_index()
    |> Enum.filter(fn {arg, _} -> arg == flag end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Checks if a flag has a specific value in an argument list.

  This replaces the duplicated `find_flag_value/3` functions across tests.

  ## Examples

      iex> find_flag_value(["--preset", "6", "--svt", "tune=0"], "--preset", "6")
      true

      iex> find_flag_value(["--preset", "4", "--svt", "tune=0"], "--preset", "6")
      false
  """
  def find_flag_value(args, flag, expected_value) do
    indices = find_flag_indices(args, flag)

    Enum.any?(indices, fn idx ->
      value = Enum.at(args, idx + 1)
      value == expected_value
    end)
  end

  @doc """
  Asserts that a flag has a specific value in an argument list.
  """
  def assert_flag_value_present(args, flag, expected_value) do
    flag_index = Enum.find_index(args, &(&1 == flag))
    assert flag_index, "Flag #{flag} not found in args: #{inspect(args)}"
    actual_value = Enum.at(args, flag_index + 1)
    assert actual_value == expected_value,
           "Expected #{flag} to have value '#{expected_value}', got '#{actual_value}'"
  end

  @doc """
  Asserts that a flag is present in an argument list.
  """
  def assert_flag_present(args, flag) do
    assert flag in args, "Flag #{flag} not found in args: #{inspect(args)}"
  end

  @doc """
  Asserts that a flag is not present in an argument list.
  """
  def refute_flag_present(args, flag) do
    refute flag in args, "Flag #{flag} should not be present in args: #{inspect(args)}"
  end

  @doc """
  Counts occurrences of a flag in an argument list.
  """
  def count_flag_occurrences(args, flag) do
    Enum.count(args, &(&1 == flag))
  end

  @doc """
  Gets all values for a specific flag in an argument list.
  """
  def get_flag_values(args, flag) do
    indices = find_flag_indices(args, flag)
    Enum.map(indices, fn idx -> Enum.at(args, idx + 1) end)
  end

  # === PATTERN MATCHING HELPERS ===

  @doc """
  Helper for testing return value pattern matching.

  This replaces the duplicated `match_return_value/1` functions across tests.
  """
  def match_return_value(return_value) do
    case return_value do
      %Reencodarr.Media.Vmaf{} -> :single_vmaf
      [_vmaf | _] -> :list_with_vmaf
      [] -> :empty_list
      nil -> :nil_value
      {:ok, value} -> {:ok, match_return_value(value)}
      {:error, _} -> :error
      _ -> :unknown
    end
  end

  # === ASSERTION HELPERS ===

  @doc """
  Asserts that video attributes match expected values.
  """
  def assert_video_attributes(video, expected_attrs) do
    Enum.each(expected_attrs, fn {key, expected_value} ->
      actual_value = Map.get(video, key)
      assert actual_value == expected_value,
             "Expected video.#{key} to be #{inspect(expected_value)}, got #{inspect(actual_value)}"
    end)
  end

  @doc """
  Asserts that argument list has expected structure and values.
  """
  def assert_args_structure(args, expected_patterns) do
    Enum.each(expected_patterns, fn
      {:has_flag, flag} -> assert_flag_present(args, flag)
      {:no_flag, flag} -> refute_flag_present(args, flag)
      {:flag_value, flag, value} -> assert_flag_value_present(args, flag, value)
      {:flag_count, flag, count} ->
        actual_count = count_flag_occurrences(args, flag)
        assert actual_count == count, "Expected #{count} occurrences of #{flag}, got #{actual_count}"
    end)
  end

  # === SVT/ENC SPECIFIC HELPERS ===

  @doc """
  Checks if SVT arguments contain specific tune values.
  """
  def svt_has_tune_value(args, tune_value) do
    find_flag_value(args, "--svt", tune_value)
  end

  @doc """
  Checks if ENC arguments contain specific encoding values.
  """
  def enc_has_value(args, enc_value) do
    find_flag_value(args, "--enc", enc_value)
  end

  @doc """
  Validates that HDR video has expected SVT flags.
  """
  def assert_hdr_svt_flags(args) do
    assert svt_has_tune_value(args, "tune=0"), "HDR video should have tune=0"
    assert svt_has_tune_value(args, "dolbyvision=1"), "HDR video should have dolbyvision=1"
  end

  # === COMMON TEST DATA GENERATORS ===

  @doc """
  Generates test data for savings calculations.
  """
  def savings_test_data do
    [
      %{original_size: 1_000_000_000, predicted_size: 500_000_000, expected_savings: 500_000_000, expected_percent: 50.0},
      %{original_size: 2_000_000_000, predicted_size: 800_000_000, expected_savings: 1_200_000_000, expected_percent: 60.0},
      %{original_size: 100_000_000, predicted_size: 90_000_000, expected_savings: 10_000_000, expected_percent: 10.0},
      %{original_size: 0, predicted_size: 0, expected_savings: 0, expected_percent: 0.0}
    ]
  end

  @doc """
  Runs savings calculations test against provided test data.
  """
  def run_savings_calculations_test(test_data, calculation_function, expected_field) do
    Enum.each(test_data, fn scenario ->
      result = calculation_function.(scenario.original_size, scenario.predicted_size)
      expected = Map.get(scenario, expected_field)

      assert result == expected,
             "Expected #{expected}, got #{result} for original: #{scenario.original_size}, predicted: #{scenario.predicted_size}"
    end)
  end

  # === VALIDATION HELPERS ===

  @doc """
  Validates that arguments don't contain duplicate flags (except allowed ones).
  """
  def assert_no_duplicate_flags(args, allowed_duplicates \\ ["--svt", "--enc"]) do
    args
    |> Enum.filter(&String.starts_with?(&1, "--"))
    |> Enum.reject(&(&1 in allowed_duplicates))
    |> Enum.frequencies()
    |> Enum.each(fn {flag, count} ->
      assert count == 1, "Flag #{flag} appears #{count} times (should be 1)"
    end)
  end

  @doc """
  Validates that argument list has proper flag-value pairing.
  """
  def assert_proper_flag_value_pairing(args) do
    flag_indices = find_all_flag_indices(args)

    Enum.each(flag_indices, fn flag_idx ->
      flag = Enum.at(args, flag_idx)

      # Skip boolean flags that don't need values
      boolean_flags = ["--verbose", "--help", "--version"]

      if flag not in boolean_flags do
        value = Enum.at(args, flag_idx + 1)
        refute value == nil, "Flag #{flag} should have a value"
        refute String.starts_with?(value || "", "--"), "Flag #{flag} value should not be another flag: #{value}"
      end
    end)
  end

  defp find_all_flag_indices(args) do
    args
    |> Enum.with_index()
    |> Enum.filter(fn {arg, _idx} -> String.starts_with?(arg, "--") end)
    |> Enum.map(fn {_arg, idx} -> idx end)
  end
end
