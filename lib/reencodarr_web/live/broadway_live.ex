defmodule ReencodarrWeb.BroadwayLive do
  @moduledoc """
  Live dashboard for Broadway pipeline monitoring.

  ## Pipeline Monitor Features:
  - Real-time pipeline state visualization
  - Producer/consumer metrics
  - Batch processing insights
  - Performance monitoring

  ## Architecture Notes:
  - Uses shared LCARS components for consistent UI
  - Memory optimized with presenter pattern
  - Real-time updates via telemetry
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
      id="broadway-live"
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
            REENCODARR OPERATIONS - PIPELINE MONITOR
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
          <span class="px-4 py-2 text-sm font-medium bg-orange-500 text-black">
            PIPELINE MONITOR
          </span>
          <.link
            navigate="/failures"
            class="px-4 py-2 text-sm font-medium text-orange-400 hover:text-orange-300 transition-colors"
          >
            FAILURES
          </.link>
        </div>
      </div>
      
    <!-- Broadway Content -->
      <div class="p-3 sm:p-6 space-y-4 sm:space-y-6">
        <div class="text-center py-12">
          <div class="text-4xl mb-4">🔄</div>
          <h2 class="text-xl text-orange-300 font-bold mb-2">PIPELINE MONITOR</h2>
          <p class="text-orange-400">Broadway pipeline monitoring interface coming soon.</p>
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
end
