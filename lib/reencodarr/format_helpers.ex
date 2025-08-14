defmodule Reencodarr.FormatHelpers do
  @moduledoc """
  Unified formatting utilities for Reencodarr.

  Consolidates formatting functionality from ProgressHelpers and CodecHelper
  into a single module for consistent data presentation.
  """

  @doc """
  Formats a numeric value for display.

  ## Examples

      iex> FormatHelpers.format_number(nil)
      "N/A"

      iex> FormatHelpers.format_number(3.14159)
      "3.14"

      iex> FormatHelpers.format_number(42)
      "42"
  """
  def format_number(nil), do: "N/A"
  def format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 2)
  def format_number(num) when is_integer(num), do: Integer.to_string(num)
  def format_number(num), do: to_string(num)

  @doc """
  Formats a percentage value for display.

  ## Examples

      iex> FormatHelpers.format_percent(nil)
      "N/A"

      iex> FormatHelpers.format_percent(85.5)
      "85.50%"

      iex> FormatHelpers.format_percent(100)
      "100%"
  """
  def format_percent(nil), do: "N/A"

  def format_percent(percent) when is_number(percent) do
    "#{format_number(percent)}%"
  end

  def format_percent(percent), do: "#{percent}%"

  @doc """
  Formats a value as a string, handling nil values gracefully.

  ## Examples

      iex> FormatHelpers.format_value(nil)
      "N/A"

      iex> FormatHelpers.format_value("Hello")
      "Hello"

      iex> FormatHelpers.format_value(42)
      "42"
  """
  def format_value(nil), do: "N/A"
  def format_value(value), do: to_string(value)

  @doc """
  Formats a filename for display, extracting series/episode information if present.

  ## Examples

      iex> FormatHelpers.format_filename("/path/to/Breaking Bad - S01E01.mkv")
      "Breaking Bad - S01E01"

      iex> FormatHelpers.format_filename("/path/to/movie.mp4")
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
  Safely parses an integer from various input types with a default fallback.

  ## Examples

      iex> FormatHelpers.parse_int("42")
      42

      iex> FormatHelpers.parse_int("invalid", 0)
      0

      iex> FormatHelpers.parse_int(nil, 100)
      100
  """
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
  Safely parses a float from various input types with a default fallback.

  ## Examples

      iex> FormatHelpers.parse_float("3.14")
      3.14

      iex> FormatHelpers.parse_float("invalid", 0.0)
      0.0
  """
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
  Gets the first non-nil, non-empty value from a list.

  ## Examples

      iex> FormatHelpers.get_first([nil, "", "valid"])
      "valid"

      iex> FormatHelpers.get_first([], "default")
      "default"
  """
  def get_first(list, default \\ nil) do
    Enum.find(list, &meaningful_value?/1) || default
  end

  @doc """
  Formats file size in bytes to human-readable format.

  Delegates to ReencodarrWeb.FormatHelpers for consistency.

  ## Examples

      iex> FormatHelpers.format_file_size(1024)
      "1.0 KB"

      iex> FormatHelpers.format_file_size(1_048_576)
      "1.0 MB"
  """
  defdelegate format_file_size(bytes), to: ReencodarrWeb.FormatHelpers

  @doc """
  Formats file size in bytes to GiB (gibibytes) with 2 decimal places.

  ## Examples

      iex> FormatHelpers.format_file_size_gib(1_073_741_824)
      1.0

      iex> FormatHelpers.format_file_size_gib(2_147_483_648)
      2.0
  """
  def format_file_size_gib(nil), do: 0.0

  def format_file_size_gib(bytes) when is_integer(bytes) and bytes >= 0 do
    Float.round(bytes / 1_073_741_824, 2)
  end

  def format_file_size_gib(_), do: 0.0

  @doc """
  Formats bitrate in bits per second to human-readable format.

  ## Examples

      iex> FormatHelpers.format_bitrate(1_000_000)
      "1.00 Mbps"

      iex> FormatHelpers.format_bitrate(500_000)
      "500.00 Kbps"
  """
  def format_bitrate(nil), do: "N/A"

  def format_bitrate(bps) when is_integer(bps) and bps >= 0 do
    cond do
      bps >= 1_000_000 -> "#{Float.round(bps / 1_000_000, 2)} Mbps"
      bps >= 1000 -> "#{Float.round(bps / 1000, 2)} Kbps"
      true -> "#{bps} bps"
    end
  end

  def format_bitrate(_), do: "N/A"

  # Additional formatting functions expected by components

  @doc """
  Formats bitrate in Mbps with 1 decimal precision.
  """
  def format_bitrate_mbps(bitrate) when is_integer(bitrate) and bitrate > 0 do
    mbps = bitrate / 1_000_000
    "#{Float.round(mbps, 1)} Mbps"
  end

  def format_bitrate_mbps(_), do: "N/A"

  @doc """
  Formats large counts with K/M suffixes.

  Delegates to ReencodarrWeb.FormatHelpers for consistency.
  """
  defdelegate format_count(count), to: ReencodarrWeb.FormatHelpers

  @doc """
  Formats FPS values with appropriate precision.

  Delegates to ReencodarrWeb.FormatHelpers for consistency.
  """
  defdelegate format_fps(fps), to: ReencodarrWeb.FormatHelpers

  @doc """
  Formats CRF values.
  """
  def format_crf(crf) when is_number(crf), do: "#{crf}"
  def format_crf(crf), do: to_string(crf)

  @doc """
  Formats VMAF scores with one decimal place.

  Delegates to ReencodarrWeb.FormatHelpers for consistency.
  """
  defdelegate format_score(score), to: ReencodarrWeb.FormatHelpers

  @doc """
  Formats ETA values as human-readable strings.

  Delegates to ReencodarrWeb.FormatHelpers for consistency.
  """
  defdelegate format_eta(eta), to: ReencodarrWeb.FormatHelpers

  @doc """
  Formats file sizes in gigabytes with 2 decimal precision.
  """
  def format_size_gb(size) when is_integer(size) and size > 0 do
    gb = size / (1024 * 1024 * 1024)
    "#{Float.round(gb, 2)} GB"
  end

  def format_size_gb(_), do: "N/A"

  @doc """
  Formats savings from GB input with appropriate units.
  """
  def format_savings_gb(nil), do: "N/A"
  def format_savings_gb(gb) when is_number(gb) and gb <= 0, do: "N/A"

  def format_savings_gb(gb) when is_number(gb) do
    cond do
      gb >= 1000 -> "#{Float.round(gb / 1000, 1)} TB"
      gb >= 1 -> "#{Float.round(gb, 1)} GB"
      gb >= 0.001 -> "#{round(gb * 1000)} MB"
      true -> "< 1 MB"
    end
  end

  def format_savings_gb(_), do: "N/A"

  @doc """
  Formats savings from bytes with appropriate units.

  Delegates to ReencodarrWeb.FormatHelpers for consistency.
  """
  defdelegate format_savings_bytes(bytes), to: ReencodarrWeb.FormatHelpers

  # Private helpers

  # Determine if a value is meaningful (not nil, empty string, or empty collection)
  defp meaningful_value?(nil), do: false
  defp meaningful_value?(""), do: false
  defp meaningful_value?([]), do: false
  defp meaningful_value?(%{} = map) when map_size(map) == 0, do: false
  defp meaningful_value?(_), do: true
end
