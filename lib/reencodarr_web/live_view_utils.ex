defmodule ReencodarrWeb.LiveViewUtils do
  @moduledoc """
  Utilities specifically for LiveView components and pages.

  Provides:
  - Standard LiveView mount patterns
  - Event handling utilities
  - CSS class generation
  - Component state management

  Focused on web-specific functionality rather than general utilities.
  """

  import Phoenix.Component, only: [assign: 3]

  # === MOUNT PATTERNS ===

  @doc """
  Standard mount setup for dashboard LiveViews.

  Provides consistent initialization pattern that can be extended.
  """
  def standard_mount(socket, additional_setup \\ fn s -> s end) do
    socket
    |> setup_common_assigns()
    |> start_periodic_updates()
    |> additional_setup.()
  end

  defp setup_common_assigns(socket) do
    socket
    |> assign(:current_time, DateTime.utc_now())
    |> assign(:timezone, "UTC")
  end

  defp start_periodic_updates(socket) do
    if connected?(socket) do
      Process.send_after(self(), :update_time, 5000)
    end

    socket
  end

  defp connected?(socket) do
    Phoenix.LiveView.connected?(socket)
  end

  # === EVENT HANDLING ===

  @doc """
  Handles timezone change events with logging.
  """
  def handle_timezone_change(socket, timezone) do
    require Logger
    Logger.debug("Setting timezone to #{timezone}")
    assign(socket, :timezone, timezone)
  end

  @doc """
  Handles time update messages.
  """
  def handle_time_update(socket) do
    Process.send_after(self(), :update_time, 5000)
    assign(socket, :current_time, DateTime.utc_now())
  end

  # === STATE MANAGEMENT ===

  @doc """
  Gets initial dashboard state with fallback for test environment.
  """
  def get_initial_dashboard_state do
    Reencodarr.DashboardState.initial()
  rescue
    _ -> %{}
  end

  @doc """
  Updates progress state with smart merging.
  """
  def smart_update_progress(current_state, new_data) do
    Enum.reduce(new_data, current_state, fn {key, value}, acc ->
      if meaningful_value?(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp meaningful_value?(value) do
    case value do
      nil -> false
      "" -> false
      [] -> false
      %{} = map when map_size(map) == 0 -> false
      _ -> true
    end
  end

  # === TELEMETRY HELPERS ===

  @doc """
  Safely handles telemetry events for LiveViews.
  """
  def handle_telemetry_event(socket, event_data) do
    assign(socket, :telemetry_data, event_data)
  rescue
    _ -> socket
  end
end
