defmodule ReencodarrWeb.DashboardLive do
  @moduledoc """
  Live dashboard for Reencodarr overview with optimized memory usage.

  ## Overview Dashboard Features:
  - Real-time metrics and system status
  - Queue monitoring and management
  - Operations control panel
  - Manual scanning interface

  ## Architecture Notes:
  - Uses shared LCARS components for consistent UI
  - Leverages presenter pattern for optimized data flow
  - Implements telemetry for real-time updates
  - Memory optimized with selective state updates
  """

  use ReencodarrWeb, :live_view

  require Logger

  alias ReencodarrWeb.Dashboard.Presenter
  alias ReencodarrWeb.DashboardLiveHelpers
  import ReencodarrWeb.LcarsComponents
  import ReencodarrWeb.DashboardComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> DashboardLiveHelpers.setup_dashboard_assigns()
      |> DashboardLiveHelpers.start_stardate_timer()
      |> setup_telemetry()
      |> setup_dashboard_data()

    {:ok, socket}
  end

  # Event Handlers

  @impl true
  def handle_info({:telemetry_event, state}, socket) do
    dashboard_data = Presenter.present(state, socket.assigns.timezone)
    socket = assign(socket, :dashboard_data, dashboard_data)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:update_stardate, socket) do
    socket = DashboardLiveHelpers.handle_stardate_update(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    Logger.debug("Setting timezone to #{tz}")
    current_state = DashboardLiveHelpers.get_initial_state()
    dashboard_data = Presenter.present(current_state, tz)

    socket =
      socket
      |> DashboardLiveHelpers.handle_timezone_change(tz)
      |> assign(:dashboard_data, dashboard_data)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    # Redirect to appropriate route instead of switching tabs locally
    case tab do
      "broadway" -> {:noreply, push_navigate(socket, to: "/broadway")}
      "failures" -> {:noreply, push_navigate(socket, to: "/failures")}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("manual_scan", %{"path" => path}, socket) do
    Logger.info("Starting manual scan for path: #{path}")
    Reencodarr.ManualScanner.scan(path)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.lcars_page_frame
      title="REENCODARR OPERATIONS - OVERVIEW"
      current_page={:overview}
      current_stardate={@current_stardate}
    >
      <.metrics_grid metrics={@dashboard_data.metrics} />
      <.operations_panel status={@dashboard_data.status} />
      <.queues_section queues={@dashboard_data.queues} />

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6">
        <.control_panel status={@dashboard_data.status} stats={@dashboard_data.stats} />
        <.manual_scan_section />
      </div>
    </.lcars_page_frame>
    """
  end

  # Lifecycle Management

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dashboard-#{inspect(self())}")
    :ok
  end

  # Private Helper Functions

  defp setup_telemetry(socket) do
    if connected?(socket) do
      :telemetry.attach_many(
        "dashboard-#{inspect(self())}",
        [[:reencodarr, :dashboard, :state_updated]],
        &__MODULE__.handle_telemetry_event/4,
        %{live_view_pid: self()}
      )
    end

    socket
  end

  defp setup_dashboard_data(socket) do
    initial_state = DashboardLiveHelpers.get_initial_state()
    dashboard_data = Presenter.present(initial_state, socket.assigns.timezone)

    assign(socket, :dashboard_data, dashboard_data)
  end

  # Telemetry event handler
  def handle_telemetry_event(
        [:reencodarr, :dashboard, :state_updated],
        _measurements,
        %{state: state},
        %{live_view_pid: pid}
      ) do
    Logger.debug(
      "DashboardLive: Received telemetry state update - syncing: #{Map.get(state, :syncing, false)}"
    )

    send(pid, {:telemetry_event, state})
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok
end
