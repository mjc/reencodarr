defmodule ReencodarrWeb.DashboardFormatters do
  @moduledoc """
  Shared formatting functions for dashboard display values.

  Provides consistent formatting for metrics, file sizes, dates, and other
  data types across all dashboard LiveViews.
  """

  @doc """
  Formats metric values with appropriate suffixes for large numbers.
  """
  def format_metric_value(value) when is_integer(value) and value >= 1000 do
    cond do
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000, 1)}M"
      value >= 1_000 -> "#{Float.round(value / 1_000, 1)}K"
      true -> to_string(value)
    end
  end

  def format_metric_value(value) when is_binary(value), do: value
  def format_metric_value(value), do: to_string(value)

  @doc """
  Formats count values with K/M suffixes for large numbers.
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
  Formats ETA values as human-readable strings.
  """
  def format_eta(eta) when is_binary(eta), do: eta
  def format_eta(eta) when is_number(eta) and eta > 0, do: "#{eta}s"
  def format_eta(_), do: "N/A"

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

  @doc """
  Formats bitrate in Mbps.
  """
  def format_bitrate_mbps(bitrate) when is_integer(bitrate) and bitrate > 0 do
    mbps = bitrate / 1_000_000
    "#{Float.round(mbps, 1)} Mbps"
  end

  def format_bitrate_mbps(_), do: "N/A"

  @doc """
  Formats file size in GB.
  """
  def format_size_gb(size) when is_integer(size) and size > 0 do
    gb = size / (1024 * 1024 * 1024)
    "#{Float.round(gb, 2)} GB"
  end

  def format_size_gb(_), do: "N/A"

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
end
