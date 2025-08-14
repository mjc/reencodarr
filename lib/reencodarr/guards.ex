defmodule Reencodarr.Guards do
  @moduledoc """
  Reusable guard macros for consistent type checking.

  Eliminates duplicated guard patterns across the application
  by providing common guard macros.
  """

  @doc """
  Guard for non-empty binary strings.
  """
  defguard is_non_empty_binary(value) when is_binary(value) and value != ""

  @doc """
  Guard for positive numbers (integers or floats > 0).
  """
  defguard is_positive_number(value) when is_number(value) and value > 0

  @doc """
  Guard for non-negative numbers (>= 0).
  """
  defguard is_non_negative_number(value) when is_number(value) and value >= 0

  @doc """
  Guard for valid file paths (non-empty strings).
  """
  defguard is_valid_path(path) when is_binary(path) and path != ""

  @doc """
  Guard for valid video dimensions (both positive numbers).
  """
  defguard are_valid_dimensions(width, height)
    when is_positive_number(width) and is_positive_number(height)

  @doc """
  Guard for valid duration values.
  """
  defguard is_valid_duration(duration) when is_positive_number(duration)

  @doc """
  Guard for non-empty lists.
  """
  defguard is_non_empty_list(list) when is_list(list) and list != []

  @doc """
  Guard for valid percentage values (0-100).
  """
  defguard is_valid_percentage(value)
    when is_number(value) and value >= 0 and value <= 100

  @doc """
  Guard for valid CRF values (typically 0-51 for video encoding).
  """
  defguard is_valid_crf(crf) when is_number(crf) and crf >= 0 and crf <= 51
end
