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

  @doc """
  Converts a value to a number (integer or float).
  Returns nil if conversion fails.
  """
  def convert_to_number(nil), do: nil
  def convert_to_number(val) when is_number(val), do: val

  def convert_to_number(val) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  def convert_to_number(_), do: nil

  @doc """
  Converts size string (e.g., "12.5 GB") to bytes for comparison with size limits.
  Uses binary prefixes (1024-based) to match Formatters module.
  """
  @unit_multipliers %{
    "b" => 1,
    # KiB
    "kb" => 1024,
    # MiB
    "mb" => 1024 * 1024,
    # GiB
    "gb" => 1024 * 1024 * 1024,
    # TiB
    "tb" => 1024 * 1024 * 1024 * 1024
  }

  def convert_size_to_bytes(size_str, unit) when is_binary(size_str) and is_binary(unit) do
    with {size_value, _} <- Float.parse(size_str),
         multiplier when not is_nil(multiplier) <-
           Map.get(@unit_multipliers, String.downcase(unit)) do
      round(size_value * multiplier)
    else
      _ -> nil
    end
  end

  def convert_size_to_bytes(_, _), do: nil

  @doc """
  Calculate estimated space savings in bytes based on percent and original video size.
  Used for VMAF calculations to estimate how much space will be saved.
  """
  def calculate_savings(nil, _video_size), do: nil
  def calculate_savings(_percent, nil), do: nil

  def calculate_savings(percent, video_size) when is_binary(percent) do
    case Float.parse(percent) do
      {percent_float, _} -> calculate_savings(percent_float, video_size)
      :error -> nil
    end
  end

  def calculate_savings(percent, video_size) when is_number(percent) and is_number(video_size) do
    if percent > 0 and percent <= 100 do
      # Savings = (100 - percent) / 100 * original_size
      round((100 - percent) / 100 * video_size)
    else
      nil
    end
  end

  def calculate_savings(_, _), do: nil
end
