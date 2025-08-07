defmodule ReencodarrWeb.FormatHelpers do
  @moduledoc """
  Unified formatting functions for the entire application.

  Consolidates formatting logic from DashboardFormatters, ProgressHelpers,
  and component-specific formatters into a single, comprehensive module.
  """

  # Size/Storage Formatting
  @doc """
  Formats file sizes with appropriate units (B, KB, MB, GB, TB).
  """
  def format_file_size(nil), do: "N/A"
  def format_file_size(bytes) when is_integer(bytes) and bytes <= 0, do: "N/A"

  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

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

  # Network/Bitrate Formatting
  @doc """
  Formats bitrate in Mbps with 1 decimal precision.
  """
  def format_bitrate_mbps(bitrate) when is_integer(bitrate) and bitrate > 0 do
    mbps = bitrate / 1_000_000
    "#{Float.round(mbps, 1)} Mbps"
  end

  def format_bitrate_mbps(_), do: "N/A"

  # Count/Metric Formatting
  @doc """
  Formats large counts with K/M suffixes.
  """
  def format_count(count) when is_integer(count) and count >= 1000 do
    cond do
      count >= 1_000_000 -> "#{Float.round(count / 1_000_000, 1)}M"
      count >= 1_000 -> "#{Float.round(count / 1_000, 1)}K"
      true -> to_string(count)
    end
  end

  def format_count(count), do: to_string(count)

  @doc """
  Formats metric values with appropriate suffixes.
  """
  def format_metric_value(value) when is_integer(value) and value >= 1000 do
    format_count(value)
  end

  def format_metric_value(value), do: to_string(value)

  # Video/Media Formatting
  @doc """
  Formats FPS values with appropriate precision.
  """
  def format_fps(fps) when is_number(fps) do
    if fps == trunc(fps) do
      "#{trunc(fps)}"
    else
      "#{Float.round(fps, 1)}"
    end
  end

  def format_fps(fps), do: to_string(fps)

  @doc """
  Formats CRF values.
  """
  def format_crf(crf) when is_number(crf), do: "#{crf}"
  def format_crf(crf), do: to_string(crf)

  @doc """
  Formats VMAF scores with one decimal place.
  """
  def format_score(score) when is_number(score) do
    "#{Float.round(score, 1)}"
  end

  def format_score(score), do: to_string(score)

  # Time/Duration Formatting
  @doc """
  Formats ETA values as human-readable strings.
  """
  def format_eta(eta) when is_binary(eta), do: eta
  def format_eta(eta) when is_number(eta) and eta > 0, do: "#{eta}s"
  def format_eta(_), do: "N/A"

  @doc """
  Converts time units to seconds for calculations.
  """
  def convert_to_seconds(time_value, unit) when is_number(time_value) do
    case String.downcase(unit) do
      "seconds" -> time_value
      "minutes" -> time_value * 60
      "hours" -> time_value * 3600
      "days" -> time_value * 86_400
      "weeks" -> time_value * 604_800
      # average month
      "months" -> time_value * 2_629_746
      # average year
      "years" -> time_value * 31_556_952
      _ -> time_value
    end
  end

  def convert_to_seconds(_, _), do: 0

  @doc """
  Formats savings from bytes with appropriate units.
  """
  def format_savings_bytes(nil), do: "N/A"

  def format_savings_bytes(bytes) when is_integer(bytes) and bytes > 0 do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_savings_bytes(_), do: "N/A"

  # Unit Conversion Utilities
  @doc """
  Gets byte multiplier for a given unit string.
  """
  def get_byte_multiplier(unit) do
    case String.downcase(unit) do
      "b" -> 1
      "kb" -> 1024
      "mb" -> 1024 * 1024
      "gb" -> 1024 * 1024 * 1024
      "tb" -> 1024 * 1024 * 1024 * 1024
      _ -> nil
    end
  end

  @doc """
  Converts size string with unit to bytes.
  """
  def size_to_bytes(size_str, unit) when is_binary(size_str) and is_binary(unit) do
    with {size_value, _} <- Float.parse(size_str),
         multiplier when not is_nil(multiplier) <- get_byte_multiplier(unit) do
      round(size_value * multiplier)
    else
      _ -> nil
    end
  end

  def size_to_bytes(_, _), do: nil
end
