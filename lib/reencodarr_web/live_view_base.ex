defmodule ReencodarrWeb.LiveViewBase do
  @moduledoc """
  Base utilities for LiveView components and pages.

  Provides common patterns like stardate calculation, timezone handling,
  and standard mount setup to eliminate duplication across LiveViews.
  """

  import Phoenix.Component, only: [assign: 3]

  @doc """
  Calculates a proper Star Trek TNG-style stardate.

  Based on TNG Writer's Guide: 1000 units = 1 year, decimal = fractional days.
  Reference: Year 2000 = Stardate 50000.0 (extrapolated from canon progression).
  """
  def calculate_stardate(datetime) do
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

  @doc """
  Standard mount setup for dashboard-style LiveViews.
  """
  def standard_mount_setup(socket, options \\ []) do
    timezone = get_in(socket.assigns, [:timezone]) || "UTC"
    current_stardate = calculate_stardate(DateTime.utc_now())

    socket
    |> assign(:timezone, timezone)
    |> assign(:current_stardate, current_stardate)
    |> maybe_setup_stardate_timer(options)
  end

  @doc """
  Handles stardate updates for LiveViews that need real-time stardate display.
  """
  def handle_stardate_update(socket) do
    # Update the stardate and schedule the next update
    Process.send_after(self(), :update_stardate, 5000)
    assign(socket, :current_stardate, calculate_stardate(DateTime.utc_now()))
  end

  @doc """
  Handles timezone changes with logging for debugging.
  """
  def handle_timezone_change_with_logging(socket, timezone) do
    require Logger
    Logger.debug("Setting timezone to #{timezone}")
    assign(socket, :timezone, timezone)
  end

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

  # Private helper functions

  defp maybe_setup_stardate_timer(socket, options) do
    if Keyword.get(options, :stardate_timer, false) and Phoenix.LiveView.connected?(socket) do
      Process.send_after(self(), :update_stardate, 5000)
    end
    socket
  end
end
