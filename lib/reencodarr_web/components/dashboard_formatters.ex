defmodule ReencodarrWeb.DashboardFormatters do
  @moduledoc """
  Dashboard formatting functions.

  Simple delegation to the centralized Reencodarr.Formatters module
  to maintain API compatibility while using the new consolidated formatters.
  """

  alias Reencodarr.Formatters

  # Delegate all formatting to the centralized module
  defdelegate format_file_size(bytes), to: Formatters
  defdelegate format_count(count), to: Formatters
  defdelegate format_fps(fps), to: Formatters
  defdelegate format_eta(eta), to: Formatters
  defdelegate format_crf(crf), to: Formatters
  defdelegate format_vmaf_score(score), to: Formatters
  defdelegate format_bitrate_mbps(bitrate), to: Formatters
  defdelegate format_size_gb(size), to: Formatters
  defdelegate format_savings_gb(gb), to: Formatters
  defdelegate format_relative_time(datetime), to: Formatters
  defdelegate format_duration(duration), to: Formatters
  defdelegate format_number(number), to: Formatters
  defdelegate format_percent(percent), to: Formatters
  defdelegate format_value(value), to: Formatters
end
