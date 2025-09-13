defmodule ReencodarrWeb.DashboardLiveHelpers do
  @moduledoc """
  Shared utilities and helper functions for dashboard LiveViews.

  Provides common functionality like stardate calculation, telemetry handling,
  and state management across all dashboard LiveViews.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  @doc """
  Calculates a proper Star Trek TNG-style stardate using the revised convention.
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
        # Approximate stardate for August 2025
        75_212.8
    end
  end

  @doc """
  Standard mount setup for all dashboard LiveViews.

  Provides consistent initialization with optional additional setup function.

  ## Examples

      # Basic usage
      socket = standard_mount_setup(socket)

      # With additional setup
      socket = standard_mount_setup(socket, fn s ->
        s |> assign(:specific_data, load_data())
      end)

  """
  def standard_mount_setup(socket, additional_setup \\ fn s -> s end) do
    socket
    |> setup_dashboard_assigns()
    |> start_stardate_timer()
    |> additional_setup.()
  end

  @doc """
  Standard timezone change handler for all dashboard LiveViews.

  Provides consistent logging and state management.
  """
  def handle_timezone_change_with_logging(socket, timezone) do
    require Logger
    Logger.debug("Setting timezone to #{timezone}")
    handle_timezone_change(socket, timezone)
  end

  @doc """
  Gets the initial dashboard state directly.
  """
  def get_initial_state do
    Reencodarr.DashboardState.initial_with_queues()
  end

  @doc """
  Gets essential dashboard state for fast initial load.
  """
  def get_essential_state do
    Reencodarr.DashboardState.initial()
  end

  @doc """
  Sets up common assigns for dashboard LiveViews.
  """
  def setup_dashboard_assigns(socket, timezone \\ "UTC") do
    _initial_state = get_initial_state()

    assign(socket,
      timezone: timezone,
      current_stardate: calculate_stardate(DateTime.utc_now())
    )
  end

  @doc """
  Starts the stardate update timer if connected.
  """
  def start_stardate_timer(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Process.send_after(self(), :update_stardate, 5000)
    end

    socket
  end

  @doc """
  Handles the stardate update message.
  """
  def handle_stardate_update(socket) do
    # Update the stardate and schedule the next update
    Process.send_after(self(), :update_stardate, 5000)

    assign(socket, :current_stardate, calculate_stardate(DateTime.utc_now()))
  end

  @doc """
  Handles timezone change events.
  """
  def handle_timezone_change(socket, timezone) do
    assign(socket, timezone: timezone)
  end
end
