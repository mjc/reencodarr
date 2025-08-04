defmodule ReencodarrWeb.HelperAliases do
  @moduledoc """
  Provides convenient aliases for migrating to unified helper modules.

  This module allows existing code to continue working while gradually
  migrating to the new consolidated helper modules.

  Note: Test helper aliases are not included here since test modules
  should directly use the unified test helpers in test/support.
  """

  # Time formatting aliases
  defdelegate relative_time(datetime), to: Reencodarr.TimeHelpers
  defdelegate format_duration(duration), to: Reencodarr.TimeHelpers

  # Format aliases
  defdelegate format_file_size(bytes), to: Reencodarr.FormatHelpers
  defdelegate format_bitrate_mbps(bitrate), to: Reencodarr.FormatHelpers
  defdelegate format_count(count), to: Reencodarr.FormatHelpers
  defdelegate format_fps(fps), to: Reencodarr.FormatHelpers
  defdelegate format_crf(crf), to: Reencodarr.FormatHelpers
  defdelegate format_score(score), to: Reencodarr.FormatHelpers
  defdelegate format_size_gb(size), to: Reencodarr.FormatHelpers
  defdelegate format_savings_gb(gb), to: Reencodarr.FormatHelpers
  defdelegate format_eta(eta), to: Reencodarr.FormatHelpers
  defdelegate format_savings_bytes(bytes), to: Reencodarr.FormatHelpers
end
