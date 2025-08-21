defmodule Reencodarr.Utils do
  @moduledoc """
  Core utility functions for the Reencodarr application.

  This module serves as the central hub for all utility functions, providing:
  - Data validation and transformation
  - Text parsing and regex operations
  - Error handling patterns
  - Guard macros for common patterns

  Replaces the scattered helper modules with a single, comprehensive utility module.
  """

  # === VALIDATION UTILITIES ===

  @doc """
  Validates that a value is present and meaningful.

  Returns true if the value is not nil, empty string, empty list, or empty map.
  """
  def present?(nil), do: false
  def present?(""), do: false
  def present?([]), do: false
  def present?(map) when map == %{}, do: false
  def present?(_), do: true

  @doc """
  Validates that a numeric value is positive.
  """
  def positive?(value) when is_number(value), do: value > 0
  def positive?(_), do: false

  @doc """
  Validates that a numeric value is within a reasonable range.
  """
  def in_range?(value, min, max) when is_number(value) do
    value >= min and value <= max
  end

  def in_range?(_, _, _), do: false

  @doc """
  Validates that a string is a valid file path.
  """
  def valid_path?(path) when is_binary(path) and path != "", do: true
  def valid_path?(_), do: false

  # === PARSING UTILITIES ===

  @doc """
  Parses a line using regex pattern and field mappings.

  Returns nil if no match, or a map with extracted and transformed fields.
  """
  def parse_with_regex(line, pattern, field_mapping) when is_binary(line) do
    case Regex.named_captures(pattern, line) do
      nil -> nil
      captures -> extract_fields(captures, field_mapping)
    end
  end

  defp extract_fields(captures, field_mapping) do
    Enum.reduce(field_mapping, %{}, fn {key, {capture_key, transformer}}, acc ->
      raw_value = Map.get(captures, capture_key)
      transformed_value = if raw_value, do: transformer.(raw_value), else: nil
      Map.put(acc, key, transformed_value)
    end)
  end

  # === GUARD MACROS ===

  @doc """
  Guard for non-empty binary values.
  """
  defguard is_non_empty_binary(value) when is_binary(value) and value != ""

  @doc """
  Guard for positive numbers.
  """
  defguard is_positive_number(value) when is_number(value) and value > 0

  @doc """
  Guard for non-negative numbers.
  """
  defguard is_non_negative_number(value) when is_number(value) and value >= 0

  @doc """
  Guard for valid percentage values (0-100).
  """
  defguard is_valid_percentage(value) when is_number(value) and value >= 0 and value <= 100

  @doc """
  Guard for non-empty lists.
  """
  defguard is_non_empty_list(value) when is_list(value) and value != []

  @doc """
  Guard for reasonable integer ranges.
  """
  defguard is_reasonable_int(value, min, max)
           when is_integer(value) and value >= min and value <= max
end
