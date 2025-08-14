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

  # === CSS UTILITIES ===

  @doc """
  Generates CSS classes for filter buttons.
  """
  def filter_button_classes(is_active, color_scheme \\ :orange) do
    base = "px-3 py-1 text-xs rounded transition-colors"

    state_classes = case {is_active, color_scheme} do
      {true, :orange} -> "bg-orange-500 text-black"
      {false, :orange} -> "bg-gray-700 text-orange-400 hover:bg-orange-600"
      {true, :blue} -> "bg-blue-500 text-white"
      {false, :blue} -> "bg-gray-700 text-blue-400 hover:bg-blue-600"
      {true, :red} -> "bg-red-500 text-white"
      {false, :red} -> "bg-gray-700 text-red-400 hover:bg-red-600"
    end

    "#{base} #{state_classes}"
  end

  @doc """
  Generates CSS classes for action buttons.
  """
  def action_button_classes do
    "px-2 py-1 bg-gray-700 text-orange-400 text-xs rounded hover:bg-orange-600 transition-colors"
  end

  @doc """
  Generates CSS classes for status badges.
  """
  def status_badge_classes(status) do
    base = "px-2 py-1 text-xs rounded"

    status_classes = case status do
      :success -> "bg-green-100 text-green-800"
      :warning -> "bg-yellow-100 text-yellow-800"
      :error -> "bg-red-100 text-red-800"
      :info -> "bg-blue-100 text-blue-800"
      _ -> "bg-gray-100 text-gray-800"
    end

    "#{base} #{status_classes}"
  end

  # === STATE MANAGEMENT ===

  @doc """
  Gets initial dashboard state with fallback for test environment.
  """
  def get_initial_dashboard_state do
    try do
      Reencodarr.DashboardState.initial()
    rescue
      _ -> %{}
    end
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
    try do
      assign(socket, :telemetry_data, event_data)
    rescue
      _ -> socket
    end
  end
end
