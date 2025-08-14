defmodule Reencodarr.NumericParser do
  @moduledoc """
  Consolidated numeric parsing utilities for MediaInfo and other parsing contexts.

  Eliminates duplication by providing a centralized place for numeric value
  parsing logic with configurable unit handling and format-specific cleaning.
  """

  @doc """
  Parses a string value into a numeric value, handling various formats and units.

  Supports configurable unit removal and cleaning patterns for different contexts
  like audio formatting, video frame rates, and general numeric values.

  ## Examples

      iex> parse_numeric("1920")
      1920

      iex> parse_numeric("23.976 fps")
      23.976

      iex> parse_numeric("48000 Hz")
      48000

      iex> parse_numeric("192 kbps")
      192

      iex> parse_numeric("invalid")
      nil

  ## Options

  - `:units` - List of unit suffixes to remove (default: common units)
  - `:preserve_float` - Whether to keep float values as floats (default: false, converts whole numbers to integers)

  """
  def parse_numeric(value, opts \\ [])
  def parse_numeric(value, opts) when is_binary(value) and value != "" do
    units = Keyword.get(opts, :units, default_units())
    preserve_float = Keyword.get(opts, :preserve_float, false)

    cleaned = clean_numeric_string(value, units)
    
    case cleaned do
      "" -> nil
      cleaned_value -> parse_cleaned_value(cleaned_value, preserve_float)
    end
  end

  def parse_numeric(value, _opts) when is_number(value), do: value
  def parse_numeric(_value, _opts), do: nil

  @doc """
  Parses numeric values specifically for audio track data.

  Handles audio-specific units like Hz, kHz, kbps, Kbps.
  """
  def parse_audio_numeric(value) do
    parse_numeric(value, units: audio_units())
  end

  @doc """
  Parses numeric values specifically for video track data.

  Handles video-specific units like fps, FPS.
  """
  def parse_video_numeric(value) do
    parse_numeric(value, units: video_units())
  end

  @doc """
  Parses numeric values for general track data.

  Uses minimal unit cleaning for general purpose numeric values.
  """
  def parse_general_numeric(value) do
    parse_numeric(value, units: [])
  end

  # Private functions

  defp clean_numeric_string(value, units) do
    # First remove unit suffixes
    value_without_units = remove_units(value, units)
    
    # Then remove any non-numeric characters except decimal points
    String.replace(value_without_units, ~r/[^\d.]/, "")
  end

  defp remove_units(value, units) do
    # Create a regex pattern that matches any of the units at the end
    if Enum.empty?(units) do
      value
    else
      unit_pattern = units |> Enum.join("|") |> then(&"\\s*(#{&1})\\s*$")
      String.replace(value, ~r/#{unit_pattern}/i, "")
    end
  end

  defp parse_cleaned_value(cleaned_value, preserve_float) do
    case Float.parse(cleaned_value) do
      {float_val, ""} -> 
        if preserve_float or float_val != trunc(float_val) do
          float_val
        else
          trunc(float_val)
        end
      {float_val, _remainder} -> 
        float_val
      :error -> 
        nil
    end
  end

  # Unit configurations

  defp default_units do
    audio_units() ++ video_units() ++ general_units()
  end

  defp audio_units do
    ["Hz", "kHz", "kbps", "Kbps", "bps"]
  end

  defp video_units do
    ["fps", "FPS"]
  end

  defp general_units do
    ["px", "MB", "GB", "TB", "KB", "%"]
  end
end
