defmodule ReencodarrWeb.BroadwayLive do
  @moduledoc """
  Live view for Broadway pipeline monitoring and metrics.

  Provides real-time monitoring of Broadway pipelines including:
  - Analyzer pipeline status and performance
  - CRF Searcher pipeline metrics
  - Encoder pipeline monitoring
  - Queue depths and processing rates
  """

  use ReencodarrWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Start timer for stardate updates (every 5 seconds)
    if connected?(socket) do
      Process.send_after(self(), :update_stardate, 5000)
    end

    timezone = socket.assigns[:timezone] || "UTC"

    socket =
      assign(socket,
        timezone: timezone,
        current_stardate: calculate_stardate(DateTime.utc_now())
      )

    {:ok, socket}
  end

  @impl true
  def handle_info(:update_stardate, socket) do
    # Update the stardate and schedule the next update
    Process.send_after(self(), :update_stardate, 5000)

    socket = assign(socket, :current_stardate, calculate_stardate(DateTime.utc_now()))
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    Logger.debug("Setting timezone to #{tz}")
    {:noreply, assign(socket, timezone: tz)}
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
            BROADWAY PIPELINE MONITOR
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
            ← OVERVIEW
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
      
    <!-- Broadway Dashboard Content -->
      <div class="p-3 sm:p-6 space-y-4 sm:space-y-6">
        <.lcars_broadway_section />
        
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

  # Calculate a proper Star Trek TNG-style stardate using the revised convention
  # Based on TNG Writer's Guide: 1000 units = 1 year, decimal = fractional days
  # Reference: Year 2000 = Stardate 50000.0 (extrapolated from canon progression)
  defp calculate_stardate(datetime) do
    with %DateTime{} <- datetime,
         current_date = DateTime.to_date(datetime),
         current_time = DateTime.to_time(datetime),
         {:ok, day_of_year} when is_integer(day_of_year) <- {:ok, Date.day_of_year(current_date)},
         {seconds_in_day, _microseconds} <- Time.to_seconds_after_midnight(current_time) do
      # Calculate years since reference (2000 = 50000.0)
      reference_year = 2000
      current_year = current_date.year
      years_diff = current_year - reference_year

      # Calculate fractional day (0.0 to 0.9)
      day_fraction = seconds_in_day / 86_400.0

      # TNG Formula: base + (years * 1000) + (day_of_year * 1000/365.25) + (day_fraction / 10)
      base_stardate = 50_000.0
      year_component = years_diff * 1000.0
      day_component = day_of_year * (1000.0 / 365.25)
      # Decimal represents tenths of days
      fractional_component = day_fraction / 10.0

      stardate = base_stardate + year_component + day_component + fractional_component

      # Format to one decimal place, TNG style
      Float.round(stardate, 1)
    else
      _ ->
        # Fallback to a simple calculation if anything goes wrong
        # Approximate stardate for mid-2025
        75_182.5
    end
  end

  defp lcars_broadway_section(assigns) do
    ~H"""
    <div class="space-y-4 sm:space-y-6">
      <!-- Pipeline Monitor Header -->
      <div class="bg-gray-900 border-2 border-orange-500 lcars-corner-tr lcars-corner-bl overflow-hidden lcars-panel">
        <div class="h-10 bg-orange-500 flex items-center px-4 lcars-data-stream">
          <span class="text-black lcars-label font-bold">BROADWAY PIPELINE MONITOR</span>
        </div>
        <div class="p-4">
          <p class="text-orange-400 text-sm mb-4">
            Live Broadway pipeline monitoring via integrated dashboard.
          </p>
          
    <!-- Broadway Dashboard Status -->
          <div class="bg-green-900/20 border border-green-500/30 rounded p-3 mb-4">
            <div class="flex items-center space-x-2">
              <div class="w-3 h-3 bg-green-500 rounded-full animate-pulse"></div>
              <span class="text-green-400 text-sm font-medium">BROADWAY DASHBOARD ACTIVE</span>
            </div>
            <p class="text-green-300 text-xs mt-2">
              Real-time pipeline monitoring and metrics available below.
            </p>
          </div>
          
    <!-- Broadway Dashboard Iframe -->
          <div class="bg-gray-800 border border-orange-500/50 rounded p-2">
            <iframe
              src="/dev/dashboard/broadway"
              class="w-full h-96 border-0 rounded bg-white"
              title="Broadway Dashboard"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
