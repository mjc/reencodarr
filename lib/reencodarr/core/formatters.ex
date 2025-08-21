defmodule Reencodarr.Core.Formatters do
  @moduledoc """
  Generic formatting utilities for data presentation and normalization.

  This module provides formatting functions for consistent data display
  and standardization across the application.
  """

  @doc """
  Formats a list of items into a comma-separated string.

  ## Examples

      iex> Formatters.format_list(["H.264", "AAC", "DTS"])
      "H.264, AAC, DTS"

      iex> Formatters.format_list([])
      ""

      iex> Formatters.format_list(["single"])
      "single"
  """
  @spec format_list(list()) :: String.t()
  def format_list(list) when is_list(list) do
    Enum.join(list, ", ")
  end

  def format_list(_), do: ""

  @doc """
  Formats file size in bytes to human-readable format.

  Delegates to Reencodarr.Formatters for consistency.

  ## Examples

      iex> Formatters.format_file_size(1024)
      "1.0 KiB"

      iex> Formatters.format_file_size(1_048_576)
      "1.0 MiB"

      iex> Formatters.format_file_size(1_073_741_824)
      "1.0 GiB"
  """
  @spec format_file_size(integer()) :: String.t()
  defdelegate format_file_size(bytes), to: Reencodarr.Formatters

  @doc """
  Formats duration in seconds to human-readable format.

  ## Examples

      iex> Formatters.format_duration(3661)
      "1h 1m 1s"

      iex> Formatters.format_duration(125)
      "2m 5s"

      iex> Formatters.format_duration(45)
      "45s"
  """
  @spec format_duration(number()) :: String.t()
  def format_duration(seconds) when is_number(seconds) and seconds >= 0 do
    hours = div(trunc(seconds), 3600)
    minutes = div(rem(trunc(seconds), 3600), 60)
    secs = rem(trunc(seconds), 60)

    parts = []
    parts = if hours > 0, do: ["#{hours}h" | parts], else: parts
    parts = if minutes > 0, do: ["#{minutes}m" | parts], else: parts
    parts = if secs > 0 or parts == [], do: ["#{secs}s" | parts], else: parts

    parts |> Enum.reverse() |> Enum.join(" ")
  end

  def format_duration(_), do: "0s"

  @doc """
  Normalizes a string by trimming whitespace and converting to lowercase.

  ## Examples

      iex> Formatters.normalize_string("  Hello World  ")
      "hello world"

      iex> Formatters.normalize_string("UPPERCASE")
      "uppercase"
  """
  @spec normalize_string(String.t()) :: String.t()
  def normalize_string(str) when is_binary(str) do
    str |> String.trim() |> String.downcase()
  end

  def normalize_string(_), do: ""
end
