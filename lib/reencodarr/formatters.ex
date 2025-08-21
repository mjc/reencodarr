defmodule Reencodarr.Formatters do
  @moduledoc """
  **UNIFIED DATA FORMATTING UTILITIES**

  Central hub for all data formatting across the Reencodarr application.
  Eliminates duplication and provides consistent, well-tested formatting.

  ## Key Features:
  - Comprehensive file size formatting (bytes, binary units, decimal units)
  - Savings and storage amount formatting
  - Numeric display formatting
  - Filename and path utilities
  - Time duration formatting

  ## File Size Standards:
  - Uses binary prefixes (1024-based): KiB, MiB, GiB, TiB
  - Decimal prefixes (1000-based) for compatibility: KB, MB, GB, TB
  - Consistent precision and edge case handling
  """

  alias Reencodarr.Core.Time

  # === FILE SIZE FORMATTING (COMPREHENSIVE) ===

  @doc """
  Formats file sizes in bytes to human-readable format using binary prefixes.

  Uses binary (1024-based) prefixes by default for accurate storage representation.

  ## Examples
      iex> format_file_size(1024)
      "1.0 KiB"

      iex> format_file_size(1_073_741_824)
      "1.0 GiB"

      iex> format_file_size(nil)
      "N/A"

      iex> format_file_size(0)
      "0 B"
  """
  def format_file_size(nil), do: "N/A"
  def format_file_size(bytes) when is_integer(bytes) and bytes < 0, do: "N/A"
  def format_file_size(0), do: "0 B"

  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 1)} TiB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MiB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KiB"
      true -> "#{bytes} B"
    end
  end

  def format_file_size(_), do: "N/A"

  @doc """
  Formats file sizes using decimal prefixes (1000-based) for compatibility.

  Some contexts prefer decimal prefixes for consistency with storage vendors.

  ## Examples
      iex> format_file_size_decimal(1000)
      "1.0 KB"

      iex> format_file_size_decimal(1_000_000_000)
      "1.0 GB"
  """
  def format_file_size_decimal(nil), do: "N/A"
  def format_file_size_decimal(bytes) when is_integer(bytes) and bytes < 0, do: "N/A"
  def format_file_size_decimal(0), do: "0 B"

  def format_file_size_decimal(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000_000 -> "#{Float.round(bytes / 1_000_000_000_000, 1)} TB"
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1000 -> "#{Float.round(bytes / 1000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_file_size_decimal(_), do: "N/A"

  @doc """
  Formats file size in bytes to GiB (gibibytes) as a numeric value.

  Returns a float for calculations and sorting. Use format_file_size/1 for display.

  ## Examples
      iex> format_file_size_gib(1_073_741_824)
      1.0

      iex> format_file_size_gib(nil)
      0.0

      iex> format_file_size_gib(1_610_612_736)
      1.5
  """
  def format_file_size_gib(bytes) when is_integer(bytes) and bytes > 0 do
    # 1 GiB = 1,073,741,824 bytes (2^30)
    gib = bytes / 1_073_741_824
    Float.round(gib, 2)
  end

  def format_file_size_gib(_), do: 0.0

  @doc """
  Formats file size with units for storage display.

  ## Examples
      iex> format_size_with_unit(2_147_483_648)
      "2.0 GiB"
  """
  def format_size_with_unit(bytes), do: format_file_size(bytes)

  # === LEGACY COMPATIBILITY FUNCTIONS ===
  # These maintain backward compatibility with existing code

  @doc """
  LEGACY: Formats file size in gigabytes with decimal precision.

  **DEPRECATED:** Use format_file_size/1 or format_file_size_gib/1 instead.
  """
  def format_size_gb(size) when is_integer(size) and size > 0 do
    gib = size / 1_073_741_824
    "#{Float.round(gib, 2)} GiB"
  end

  def format_size_gb(_), do: "N/A"

  # === SAVINGS FORMATTING ===

  @doc """
  Formats savings amounts with appropriate units (handles GB input).

  For savings calculations that come as GB values.

  ## Examples
      iex> format_savings_gb(2.5)
      "2.5 GiB"

      iex> format_savings_gb(1500.0)
      "1.5 TiB"
  """
  def format_savings_gb(nil), do: "N/A"
  def format_savings_gb(gb) when is_number(gb) and gb <= 0, do: "N/A"

  def format_savings_gb(gb) when is_number(gb) do
    cond do
      gb >= 1000 -> "#{Float.round(gb / 1000, 1)} TiB"
      gb >= 1 -> "#{Float.round(gb, 2)} GiB"
      gb >= 0.001 -> "#{round(gb * 1000)} MiB"
      true -> "< 1 MiB"
    end
  end

  def format_savings_gb(_), do: "N/A"

  @doc """
  Formats savings amounts from bytes with appropriate units.

  ## Examples
      iex> format_savings_bytes(1_073_741_824)
      "1.0 GiB"
  """
  def format_savings_bytes(nil), do: "N/A"
  def format_savings_bytes(bytes) when is_integer(bytes) and bytes <= 0, do: "N/A"

  def format_savings_bytes(bytes) when is_integer(bytes) do
    format_file_size(bytes)
  end

  def format_savings_bytes(_), do: "N/A"

  # === NUMERIC FORMATTING ===

  @doc """
  Formats numeric values for display.
  """
  def format_number(nil), do: "N/A"
  def format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 2)
  def format_number(num) when is_integer(num), do: Integer.to_string(num)
  def format_number(num), do: to_string(num)

  @doc """
  Formats percentage values.
  """
  def format_percent(nil), do: "N/A"

  def format_percent(percent) when is_number(percent) do
    "#{format_number(percent)}%"
  end

  def format_percent(percent), do: "#{percent}%"

  @doc """
  Formats large counts with K/M suffixes.
  """
  def format_count(count) when is_integer(count) and count >= 1_000_000 do
    "#{Float.round(count / 1_000_000, 1)}M"
  end

  def format_count(count) when is_integer(count) and count >= 1000 do
    "#{Float.round(count / 1000, 1)}K"
  end

  def format_count(count), do: to_string(count)

  # === VIDEO/AUDIO FORMATTING ===

  @doc """
  Formats bitrate in Mbps.
  """
  def format_bitrate_mbps(bitrate) when is_integer(bitrate) and bitrate > 0 do
    mbps = bitrate / 1_000_000
    "#{Float.round(mbps, 1)} Mbps"
  end

  def format_bitrate_mbps(_), do: "N/A"

  @doc """
  Formats FPS values.
  """
  def format_fps(fps) when is_number(fps) do
    if fps == trunc(fps) do
      "#{trunc(fps)} fps"
    else
      "#{Float.round(fps, 3)} fps"
    end
  end

  def format_fps(fps), do: to_string(fps)

  @doc """
  Formats CRF values.
  """
  def format_crf(crf) when is_number(crf), do: "#{crf}"
  def format_crf(crf), do: to_string(crf)

  @doc """
  Formats VMAF scores.
  """
  def format_vmaf_score(score) when is_number(score) do
    "#{Float.round(score, 1)}"
  end

  def format_vmaf_score(score), do: to_string(score)

  # === TIME FORMATTING ===

  @doc """
  Formats relative time (e.g., "2 hours ago").
  """
  def format_relative_time(nil), do: "Never"

  def format_relative_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_relative_time(dt)
      _ -> "Invalid date"
    end
  end

  def format_relative_time(%DateTime{} = datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds} seconds ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86_400)} days ago"
      true -> "#{div(diff_seconds, 2_592_000)} months ago"
    end
  end

  def format_relative_time(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> format_relative_time()
  end

  @doc """
  Formats duration values using centralized Core.Time functions.
  """
  def format_duration(duration), do: Time.format_duration(duration)

  @doc """
  Formats ETA values using centralized Core.Time functions.
  """
  def format_eta(eta), do: Time.format_eta(eta)

  # === GENERAL UTILITIES ===

  @doc """
  Formats any value as a string with nil handling.
  """
  def format_value(nil), do: "N/A"
  def format_value(value), do: to_string(value)

  @doc """
  Formats filename for display, extracting series/episode info if present.
  """
  def format_filename(path) when is_binary(path) do
    basename = Path.basename(path, Path.extname(path))

    # Try to extract series/episode pattern
    case Regex.run(~r/(.+)\s-\s(S\d+E\d+)/, basename) do
      [_, series, episode] -> "#{series} - #{episode}"
      _ -> basename <> Path.extname(path)
    end
  end

  def format_filename(_), do: "N/A"

  @doc """
  Formats a list of items as comma-separated string.
  """
  def format_list(list) when is_list(list), do: Enum.join(list, ", ")
  def format_list(_), do: ""

  @doc """
  Normalizes a string by trimming whitespace and converting to lowercase.

  ## Examples

      iex> normalize_string("  Hello World  ")
      "hello world"

      iex> normalize_string("UPPERCASE")
      "uppercase"
  """
  def normalize_string(str) when is_binary(str) do
    str |> String.trim() |> String.downcase()
  end

  def normalize_string(_), do: ""
end
