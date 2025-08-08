defmodule Reencodarr.Core.Parsers do
  @moduledoc """
  Generic parsing utilities for various data types and formats.

  This module provides safe parsing functions with fallback defaults
  for common data transformations needed throughout the application.
  """

  @doc """
  Parses duration string in various formats to seconds.

  Supports formats like:
  - "1:23:45" (1 hour, 23 minutes, 45 seconds)
  - "23:45" (23 minutes, 45 seconds)
  - "45" (45 seconds)

  ## Examples

      iex> Parsers.parse_duration("1:23:45")
      5025

      iex> Parsers.parse_duration("23:45")
      1425

      iex> Parsers.parse_duration(3600.0)
      3600.0
  """
  @spec parse_duration(String.t() | number()) :: number()
  def parse_duration(duration) when is_binary(duration) do
    case String.split(duration, ":") do
      [hours, minutes, seconds] ->
        String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
          String.to_integer(seconds)

      [minutes, seconds] ->
        String.to_integer(minutes) * 60 + String.to_integer(seconds)

      [seconds] ->
        String.to_integer(seconds)

      _ ->
        0
    end
  end

  def parse_duration(duration) when is_number(duration), do: duration
  def parse_duration(_), do: 0

  @doc """
  Safely parses an integer with fallback to default value.

  ## Examples

      iex> Parsers.parse_int("123", 0)
      123

      iex> Parsers.parse_int("invalid", 42)
      42

      iex> Parsers.parse_int(456, 0)
      456
  """
  @spec parse_int(any(), integer()) :: integer()
  def parse_int(val, default \\ 0)
  def parse_int(val, _default) when is_integer(val), do: val

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> default
    end
  end

  def parse_int(_, default), do: default

  @doc """
  Safely parses a float with fallback to default value.

  ## Examples

      iex> Parsers.parse_float("123.45", 0.0)
      123.45

      iex> Parsers.parse_float("invalid", 3.14)
      3.14

      iex> Parsers.parse_float(456.78, 0.0)
      456.78
  """
  @spec parse_float(any(), float()) :: float()
  def parse_float(val, default \\ 0.0)
  def parse_float(val, _default) when is_float(val), do: val

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  def parse_float(_, default), do: default

  @doc """
  Parses resolution string (e.g., "1920x1080") to width/height tuple.

  ## Examples

      iex> Parsers.parse_resolution("1920x1080")
      {1920, 1080}

      iex> Parsers.parse_resolution("invalid")
      {0, 0}

      iex> Parsers.parse_resolution(nil)
      {0, 0}
  """
  @spec parse_resolution(String.t() | nil) :: {integer(), integer()}
  def parse_resolution(res) do
    [w, h] = (res || "0x0") |> String.split("x") |> Enum.map(&parse_int(&1, 0))
    {w, h}
  end

  @doc """
  Gets the first non-nil value from a list.

  ## Examples

      iex> Parsers.get_first([nil, "", "hello", "world"])
      "hello"

      iex> Parsers.get_first([nil, nil], "default")
      "default"
  """
  @spec get_first(list(), any()) :: any()
  def get_first(list, default \\ nil) do
    Enum.find(list, & &1) || default
  end
end
