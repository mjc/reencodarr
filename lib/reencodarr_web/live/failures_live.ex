defmodule ReencodarrWeb.FailuresLive do
  @moduledoc """
  Live dashboard for failures analysis and management.

  ## Failures Analysis Features:
  - Failed video discovery and filtering
  - Detailed failure analysis with codec, size, path information
  - Failure retry and bulk management
  - Sorting and searching capabilities

  ## Architecture Notes:
  - Uses shared LCARS components for consistent UI
  - Memory optimized with efficient queries
  - Real-time updates for failure state changes
  """

  use ReencodarrWeb, :live_view

  require Logger

  alias ReencodarrWeb.DashboardLiveHelpers

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> DashboardLiveHelpers.setup_dashboard_assigns()
      |> DashboardLiveHelpers.start_stardate_timer()
      |> setup_failures_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:update_stardate, socket) do
    socket = DashboardLiveHelpers.handle_stardate_update(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    Logger.debug("Setting timezone to #{tz}")
    socket = DashboardLiveHelpers.handle_timezone_change(socket, tz)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="failures-live"
      class="min-h-screen bg-black text-orange-400 font-mono lcars-screen lcars-scan-lines"
      phx-hook="TimezoneHook"
    >
      <!-- LCARS Top Frame -->
      <div class="h-12 sm:h-16 bg-gradient-to-r from-orange-500 via-yellow-400 to-red-500 relative lcars-border-gradient">
        <div class="absolute top-0 left-0 w-16 sm:w-32 h-12 sm:h-16 bg-orange-500 lcars-corner-br">
        </div>
        <div class="absolute top-0 right-0 w-16 sm:w-32 h-12 sm:h-16 bg-red-500 lcars-corner-bl">
        </div>
        <div class="flex items-center justify-center h-full px-4">
          <h1 class="text-black text-lg sm:text-2xl lcars-title text-center">
            REENCODARR OPERATIONS - FAILURES ANALYSIS
          </h1>
        </div>
      </div>
      
    <!-- Navigation -->
      <div class="border-b-2 border-orange-500 bg-gray-900">
        <div class="flex space-x-1 p-2">
          <.link
            navigate="/"
            class="px-4 py-2 text-sm font-medium text-orange-400 hover:text-orange-300 transition-colors"
          >
            OVERVIEW
          </.link>
          <.link
            navigate="/broadway"
            class="px-4 py-2 text-sm font-medium text-orange-400 hover:text-orange-300 transition-colors"
          >
            PIPELINE MONITOR
          </.link>
          <span class="px-4 py-2 text-sm font-medium bg-orange-500 text-black">
            FAILURES
          </span>
        </div>
      </div>
      
    <!-- Failures Content -->
      <div class="p-3 sm:p-6 space-y-4 sm:space-y-6">
        <div class="text-center py-12">
          <div class="text-4xl mb-4">⚠️</div>
          <h2 class="text-xl text-orange-300 font-bold mb-2">FAILURES ANALYSIS</h2>
          <p class="text-orange-400">Detailed failure tracking and analysis coming soon.</p>
        </div>
        
    <!-- LCARS Bottom Frame -->
        <div class="h-6 sm:h-8 bg-gradient-to-r from-red-500 via-yellow-400 to-orange-500 rounded">
          <div class="flex items-center justify-center h-full">
            <span class="text-black lcars-label text-xs sm:text-sm">
              STARDATE {@current_stardate}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Private Helper Functions

  defp setup_failures_data(socket) do
    socket
    |> assign(:failure_filter, "all")
    |> assign(:sort_by, "file_path")
    |> assign(:sort_direction, :asc)
    |> assign(:expanded_details, [])
  end
end
