defmodule Reencodarr.ProgressHelpers do
  @moduledoc """
  Utilities for progress tracking, updating, and formatting across the application.

  This module provides both progress update logic and consistent formatting
  for various progress-related data types.
  """

  # Progress Update Functions

  @doc """
  Smart merge that only updates fields with meaningful new values, preserving existing values otherwise.
  """
  def smart_merge(current_map, new_map) do
    Enum.reduce(new_map, current_map, fn {key, new_value}, acc ->
      if meaningful_value?(key, new_value) do
        Map.put(acc, key, new_value)
      else
        acc
      end
    end)
  end

  @doc """
  Update progress struct with new measurements, preserving meaningful existing values.
  """
  def update_progress(current_progress, measurements) when is_struct(current_progress) and is_map(measurements) do
    current_map = Map.from_struct(current_progress)
    updated_map = smart_merge(current_map, measurements)
    struct(current_progress.__struct__, updated_map)
  end

  @doc """
  Create a fresh progress struct for a new operation.
  """
  def fresh_progress(progress_module, attrs \\ %{}) do
    struct(progress_module, attrs)
  end

  # Formatting Functions

  @doc """
  Formats a numeric value for display.

  ## Examples

      iex> ProgressHelpers.format_number(nil)
      "N/A"

      iex> ProgressHelpers.format_number(3.14159)
      "3.14"

      iex> ProgressHelpers.format_number(42)
      "42"
  """
  def format_number(nil), do: "N/A"
  def format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 2)
  def format_number(num) when is_integer(num), do: Integer.to_string(num)
  def format_number(num), do: to_string(num)

  @doc """
  Formats a percentage value for display.

  ## Examples

      iex> ProgressHelpers.format_percent(nil)
      "N/A"

      iex> ProgressHelpers.format_percent(85.5)
      "85.50%"

      iex> ProgressHelpers.format_percent(100)
      "100%"
  """
  def format_percent(nil), do: "N/A"

  def format_percent(percent) when is_number(percent) do
    "#{format_number(percent)}%"
  end

  def format_percent(percent), do: "#{percent}%"

  @doc """
  Formats a filename for display, extracting series/episode information if present.

  ## Examples

      iex> ProgressHelpers.format_filename("/path/to/Breaking Bad - S01E01.mkv")
      "Breaking Bad - S01E01"

      iex> ProgressHelpers.format_filename("/path/to/movie.mp4")
      "movie.mp4"
  """
  def format_filename(path) when is_binary(path) do
    path = Path.basename(path)

    case Regex.run(~r/^(.+?) - (S\d+E\d+)/, path) do
      [_, series_name, episode_name] -> "#{series_name} - #{episode_name}"
      [_, movie_name] -> movie_name
      _ -> path
    end
  end

  def format_filename(_), do: "N/A"

  @doc """
  Formats a value as a string, handling nil values gracefully.

  ## Examples

      iex> ProgressHelpers.format_value(nil)
      "N/A"

      iex> ProgressHelpers.format_value("Hello")
      "Hello"

      iex> ProgressHelpers.format_value(42)
      "42"
  """
  def format_value(nil), do: "N/A"
  def format_value(value), do: to_string(value)

  @doc """
  Formats a duration or ETA value for display.
  """
  def format_duration(nil), do: "N/A"
  def format_duration(0), do: "N/A"
  def format_duration(duration), do: to_string(duration)

  # Private helper functions

  # Determine if a value is meaningful for updating progress
  defp meaningful_value?(key, value) do
    case {key, value} do
      {_, v} when v in [nil, "", :none] -> false
      {_, []} -> false
      {_, %{} = map} when map_size(map) == 0 -> false
      # For CRF and score, 0 is not meaningful (these should be positive numbers)
      {k, 0} when k in [:crf, :score] -> false
      {k, v} when k in [:crf, :score] and v == 0.0 -> false
      # For other values, 0 can be meaningful (like 0% progress at start)
      {_, _} -> true
    end
  end
end
