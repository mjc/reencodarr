defmodule Reencodarr.GuardHelpers do
  @moduledoc """
  Consolidated guard macros to eliminate duplication.

  Provides reusable guard patterns that appear frequently across the codebase,
  reducing repetition and ensuring consistency.
  """

  @doc """
  Guard for non-empty binary values.

  ## Examples

      defp process_name(name) when is_non_empty_binary(name) do
        # process the name
      end

  """
  defguard is_non_empty_binary(value)
           when is_binary(value) and value != ""

  @doc """
  Guard for positive numbers (both integer and float).

  ## Examples

      defp calculate_area(width, height)
        when is_positive_number(width) and is_positive_number(height) do
        width * height
      end

  """
  defguard is_positive_number(value)
           when is_number(value) and value > 0

  @doc """
  Guard for non-negative numbers (zero or positive).

  ## Examples

      defp format_count(count) when is_non_negative_number(count) do
        # format the count
      end

  """
  defguard is_non_negative_number(value)
           when is_number(value) and value >= 0

  @doc """
  Guard for valid file paths (non-empty binaries).

  ## Examples

      defp process_file(path) when is_valid_path(path) do
        # process the file
      end

  """
  defguard is_valid_path(path)
           when is_binary(path) and path != ""

  @doc """
  Guard for reasonable integer ranges.

  ## Examples

      defp set_channels(channels) when is_reasonable_int(channels, 1, 32) do
        # set audio channels
      end

  """
  defguard is_reasonable_int(value, min, max)
           when is_integer(value) and value >= min and value <= max

  @doc """
  Guard for valid percentage values (0-100).

  ## Examples

      defp set_progress(percent) when is_valid_percentage(percent) do
        # update progress
      end

  """
  defguard is_valid_percentage(value)
           when is_number(value) and value >= 0 and value <= 100

  @doc """
  Guard for non-empty lists.

  ## Examples

      defp process_items(items) when is_non_empty_list(items) do
        # process the list
      end

  """
  defguard is_non_empty_list(value)
           when is_list(value) and length(value) > 0

  @doc """
  Guard for valid video dimensions.

  ## Examples

      defp set_resolution(width, height) when are_valid_dimensions(width, height) do
        # set video resolution
      end

  """
  defguard are_valid_dimensions(width, height)
           when is_integer(width) and is_integer(height) and width > 0 and height > 0

  @doc """
  Guard for valid duration values (positive numbers representing seconds).

  ## Examples

      defp format_duration(seconds) when is_valid_duration(seconds) do
        # format duration
      end

  """
  defguard is_valid_duration(value)
           when is_number(value) and value > 0

  @doc """
  Guard for valid bitrate values (positive integers representing bits per second).

  ## Examples

      defp format_bitrate(bps) when is_valid_bitrate(bps) do
        # format bitrate
      end

  """
  defguard is_valid_bitrate(value)
           when is_integer(value) and value > 0
end
