defmodule Reencodarr.ProgressHelpers do
  @moduledoc """
  Utilities for progress tracking, updating, and state management.

  This module focuses on progress update logic and state management,
  while formatting functions have been moved to Reencodarr.FormatHelpers.
  """

  alias Reencodarr.FormatHelpers

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
  def update_progress(current_progress, measurements)
      when is_struct(current_progress) and is_map(measurements) do
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

  # Formatting Functions (delegated to FormatHelpers for consistency)

  @doc """
  Formats a numeric value for display.
  Delegates to FormatHelpers.format_number/1.
  """
  def format_number(value), do: FormatHelpers.format_number(value)

  @doc """
  Formats a percentage value for display.
  Delegates to FormatHelpers.format_percent/1.
  """
  def format_percent(value), do: FormatHelpers.format_percent(value)

  @doc """
  Formats a filename for display.
  Delegates to FormatHelpers.format_filename/1.
  """
  def format_filename(path), do: FormatHelpers.format_filename(path)

  @doc """
  Formats a value as a string, handling nil values gracefully.
  Delegates to FormatHelpers.format_value/1.
  """
  def format_value(value), do: FormatHelpers.format_value(value)

  @doc """
  Formats a duration or ETA value for display.
  Delegates to Reencodarr.TimeHelpers.format_duration/1.
  """
  def format_duration(duration), do: Reencodarr.TimeHelpers.format_duration(duration)

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
