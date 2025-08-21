defmodule Reencodarr.DataConverters do
  @moduledoc """
  Data conversion utilities for parsing and transforming data types.
  """

  alias Reencodarr.Core.Parsers

  @doc """
  Parses a resolution string like "1920x1080" into {:ok, {width, height}} tuple.
  Returns {:error, reason} if parsing fails.
  """
  def parse_resolution(resolution_string) when is_binary(resolution_string) do
    case String.split(resolution_string, "x") do
      [width_str, height_str] ->
        with {width, ""} <- Integer.parse(width_str),
             {height, ""} <- Integer.parse(height_str) do
          {:ok, {width, height}}
        else
          _ -> {:error, "Invalid resolution format: #{resolution_string}"}
        end

      _ ->
        {:error, "Invalid resolution format: #{resolution_string}"}
    end
  end

  def parse_resolution({width, height}) when is_integer(width) and is_integer(height) do
    {:ok, {width, height}}
  end

  def parse_resolution(nil) do
    {:error, "Resolution cannot be nil"}
  end

  def parse_resolution(other) do
    {:error, "Invalid resolution format: #{inspect(other)}"}
  end

  @doc """
  Parses a resolution string like "1920x1080" into a tuple {width, height}.
  Returns the given fallback (default {0, 0}) if parsing fails.
  """
  def parse_resolution_with_fallback(resolution_string, fallback \\ {0, 0}) do
    case parse_resolution(resolution_string) do
      {:ok, resolution} -> resolution
      {:error, _} -> fallback
    end
  end

  @doc """
  Formats a resolution tuple to a string like "1920x1080".
  """
  def format_resolution({width, height}) do
    "#{width}x#{height}"
  end

  @doc """
  Validates if a resolution tuple represents a reasonable video resolution.
  """
  def valid_resolution?({width, height}) when is_integer(width) and is_integer(height) do
    width > 0 and height > 0 and width <= 7680 and height <= 4320
  end

  def valid_resolution?(_), do: false

  @doc """
  Parses duration using centralized Core.Parsers functions.
  """
  def parse_duration(duration), do: Parsers.parse_duration(duration)

  @doc """
  Parses numeric values from strings, removing specified units.
  """
  def parse_numeric(value, opts \\ [])

  def parse_numeric(value, opts) when is_binary(value) do
    units = Keyword.get(opts, :units, [])

    cleaned =
      Enum.reduce(units, value, fn unit, acc ->
        String.replace(acc, unit, "", global: true)
      end)

    cleaned = String.trim(cleaned)

    case Float.parse(cleaned) do
      {number, ""} ->
        number

      {number, _} ->
        number

      :error ->
        case Integer.parse(cleaned) do
          {number, ""} -> number * 1.0
          {number, _} -> number * 1.0
          :error -> 0.0
        end
    end
  end

  def parse_numeric(value, _opts) when is_number(value), do: value * 1.0
  def parse_numeric(_value, _opts), do: 0.0
end
