defmodule ReencodarrWeb.DashboardFormatters do
  @moduledoc """
  Shared formatting functions for dashboard display values.

  Delegates to centralized formatting modules to eliminate duplication
  and ensure consistency across all dashboard LiveViews.
  """

  # Import centralized formatters
  alias ReencodarrWeb.FormatHelpers, as: WebFormatHelpers

  # === DELEGATION TO CENTRALIZED FORMATTERS ===
  # These delegate to avoid duplication across multiple modules

  @doc """
  Formats metric values with appropriate suffixes for large numbers.
  """
  defdelegate format_metric_value(value), to: WebFormatHelpers

  @doc """
  Formats count values with K/M suffixes for large numbers.
  """
  defdelegate format_count(count), to: WebFormatHelpers

  @doc """
  Formats FPS values with appropriate precision.
  """
  defdelegate format_fps(fps), to: WebFormatHelpers

  @doc """
  Formats ETA values as human-readable strings.
  """
  defdelegate format_eta(eta), to: WebFormatHelpers

  @doc """
  Formats CRF values.
  """
  defdelegate format_crf(crf), to: WebFormatHelpers

  @doc """
  Formats VMAF scores with one decimal place.
  """
  defdelegate format_score(score), to: WebFormatHelpers

  @doc """
  Formats bitrate in Mbps.
  """
  defdelegate format_bitrate_mbps(bitrate), to: WebFormatHelpers

  @doc """
  Formats file size in GB.
  """
  defdelegate format_size_gb(size), to: WebFormatHelpers

  @doc """
  Formats savings from bytes with appropriate units.
  """
  defdelegate format_savings_bytes(bytes), to: WebFormatHelpers
end
