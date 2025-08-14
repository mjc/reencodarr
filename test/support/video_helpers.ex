defmodule Reencodarr.TestHelpers.VideoHelpers do
  @moduledoc """
  Common test helpers for video-related testing to reduce code duplication.

  This module provides standardized helpers for creating test videos, VMAFs,
  and calculating expected savings across multiple test files.
  """

  import ExUnit.Assertions
  alias Reencodarr.{Media, Media.Vmaf}

  @doc """
  Creates a test video with default attributes that can be overridden.
  """
  def create_test_video(attrs \\ %{}) do
    # Use the consolidated pattern from TestPatterns, but create database video
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
      # Required field
      score: 95.0,
      # Required field - array of strings
      params: [],
      savings: calculate_default_savings(video.size, 500_000_000)
    }

    attrs = Map.merge(default_attrs, attrs)

    %Vmaf{}
    |> Vmaf.changeset(attrs)
    |> Reencodarr.Repo.insert!()
  end

  @doc """
  Creates a chosen VMAF for encoding queue testing.
  """
  def create_chosen_vmaf(video, attrs \\ %{}) do
    attrs = Map.merge(attrs, %{chosen: true})
    create_test_vmaf(video, attrs)
  end

  @doc """
  Calculates expected savings between original and predicted file sizes.
  """
  def calculate_expected_savings(original_size, predicted_size)
      when is_integer(original_size) and is_integer(predicted_size) do
    case original_size do
      0 -> 0
      _ -> original_size - predicted_size
    end
  end

  def calculate_expected_savings(_, _), do: 0

  @doc """
  Calculates percentage savings between original and predicted file sizes.
  """
  def calculate_percentage_savings(original_size, predicted_size)
      when is_integer(original_size) and is_integer(predicted_size) do
    case original_size do
      0 -> 0.0
      _ -> (original_size - predicted_size) / original_size * 100
    end
  end

  def calculate_percentage_savings(_, _), do: 0.0

  @doc """
  Creates multiple test videos with incremental attributes for testing sorting/filtering.
  """
  def create_test_video_series(count, base_attrs \\ %{}) do
    1..count
    |> Enum.map(fn i ->
      attrs =
        Map.merge(base_attrs, %{
          path: "/test/video_#{i}.mkv",
          size: 1_000_000_000 + i * 100_000_000,
          bitrate: 5000 + i * 100,
          service_id: "#{i}"
        })

      create_test_video(attrs)
    end)
  end

  @doc """
  Sets up a complete encoding scenario with video and chosen VMAF.
  """
  def setup_encoding_scenario(video_attrs \\ %{}, vmaf_attrs \\ %{}) do
    video = create_test_video(video_attrs)
    vmaf = create_chosen_vmaf(video, vmaf_attrs)
    {video, vmaf}
  end

  @doc """
  Creates test data for savings calculation scenarios.
  """
  def create_savings_test_data do
    [
      # Large savings scenario
      %{
        original_size: 2_000_000_000,
        predicted_size: 800_000_000,
        expected_savings: 1_200_000_000,
        expected_percent: 60.0
      },

      # Medium savings scenario
      %{
        original_size: 1_000_000_000,
        predicted_size: 700_000_000,
        expected_savings: 300_000_000,
        expected_percent: 30.0
      },

      # Small savings scenario
      %{
        original_size: 500_000_000,
        predicted_size: 450_000_000,
        expected_savings: 50_000_000,
        expected_percent: 10.0
      },

      # No savings scenario (larger predicted size)
      %{
        original_size: 1_000_000_000,
        predicted_size: 1_100_000_000,
        expected_savings: -100_000_000,
        expected_percent: -10.0
      },

      # Zero original size edge case
      %{original_size: 0, predicted_size: 500_000_000, expected_savings: 0, expected_percent: 0.0}
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

  @doc """
  Validates video attributes match expected values.
  """
  def assert_video_attributes(video, expected_attrs) do
    Enum.each(expected_attrs, fn {key, expected_value} ->
      actual_value = Map.get(video, key)

      assert actual_value == expected_value,
             "Expected video.#{key} to be #{inspect(expected_value)}, got #{inspect(actual_value)}"
    end)
  end

  @doc """
  Creates a minimal test video for quick testing scenarios.
  """
  def create_minimal_test_video(path \\ "/test/minimal.mkv") do
    create_test_video(%{
      path: path,
      size: 1_000_000,
      bitrate: 1000,
      duration: 600.0
    })
  end

  # Private helper function
  defp calculate_default_savings(original_size, predicted_size) do
    calculate_expected_savings(original_size, predicted_size)
  end
end
