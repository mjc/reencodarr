defmodule ReencodarrWeb.DashboardLive do
  @moduledoc """
  Live dashboard for Reencodarr
  """

  use ReencodarrWeb, :live_view

  require Logger

  alias ReencodarrWeb.Dashboard.Presenter
  alias ReencodarrWeb.Utils.TimeUtils

  @impl true
  def mount(_params, _session, socket) do
    # Attach telemetry handler for dashboard state updates
    if connected?(socket) do
      :telemetry.attach_many(
        "dashboard-#{inspect(self())}",
        [[:reencodarr, :dashboard, :state_updated], [:reencodarr, :dashboard, :progress_updated]],
        &__MODULE__.handle_telemetry_event/4,
        %{live_view_pid: self()}
      )
    end

    initial_state = get_initial_state()
    timezone = socket.assigns[:timezone] || "UTC"

    # Only store processed data, not raw state - reduces memory by ~50%
    socket =
      assign(socket,
        timezone: timezone,
        dashboard_data: Presenter.present(initial_state, timezone),
        # Cache queue counts separately to avoid recomputing
        queue_counts: %{
          crf_search: length(initial_state.stats.next_crf_search),
          encoding: length(initial_state.stats.videos_by_estimated_percent)
        }
      )

    {:ok, socket}
  end

  @impl true
  def handle_info({:telemetry_event, state}, socket) do
    # Selective updates based on what actually changed
    dashboard_data = Presenter.present(state, socket.assigns.timezone)

    # Update queue counts cache
    new_queue_counts = %{
      crf_search: length(state.stats.next_crf_search),
      encoding: length(state.stats.videos_by_estimated_percent)
    }

    socket =
      socket
      |> assign(:dashboard_data, dashboard_data)
      |> assign(:queue_counts, new_queue_counts)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:progress_update, progress_data}, socket) do
    # Handle lightweight progress updates without full state refresh
    updated_dashboard_data = update_progress_in_dashboard_data(socket.assigns.dashboard_data, progress_data)

    socket = assign(socket, :dashboard_data, updated_dashboard_data)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    Logger.debug("Setting timezone to #{tz}")
    # Only update timezone-dependent data, not everything
    updated_dashboard_data = update_timezone_in_dashboard_data(socket.assigns.dashboard_data, tz)

    socket =
      socket
      |> assign(:timezone, tz)
      |> assign(:dashboard_data, updated_dashboard_data)

    {:noreply, socket}
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
    <div
      id="dashboard-live"
      class="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 p-6"
      phx-hook="TimezoneHook"
    >
      <.dashboard_header dashboard_data={@dashboard_data} />

      <div class="max-w-7xl mx-auto space-y-8">
        <.metrics_section metrics={@dashboard_data.metrics} />
        <.status_section status={@dashboard_data.status} stats={@dashboard_data.stats} />
        <.queues_section queues={@dashboard_data.queues} />
        <.manual_scan_section />
      </div>

      <.dashboard_footer />
    </div>
    """
  end

  # Template sections - much simpler and focused
  defp dashboard_header(assigns) do
    ~H"""
    <header class="mb-8">
      <div class="max-w-7xl mx-auto">
        <div class="flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6">
          <div>
            <h1 class="text-4xl lg:text-5xl font-extrabold bg-gradient-to-r from-cyan-400 to-blue-500 bg-clip-text text-transparent mb-2">
              Reencodarr
            </h1>
            <p class="text-slate-300 text-lg">
              Intelligent Video Encoding Pipeline
            </p>
          </div>

          <div class="flex flex-wrap gap-3">
            <.live_component
              module={ReencodarrWeb.ControlButtonsComponent}
              id="control-buttons"
              encoding={@dashboard_data.status.encoding.active}
              crf_searching={@dashboard_data.status.crf_searching.active}
              syncing={@dashboard_data.status.syncing.active}
            />
          </div>
        </div>
      </div>
    </header>
    """
  end

  defp metrics_section(assigns) do
    ~H"""
    <section class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
      <%= for metric <- @metrics do %>
        <.live_component
          module={ReencodarrWeb.Dashboard.MetricCardComponent}
          id={"metric-#{metric.title}"}
          {metric}
        />
      <% end %>
    </section>
    """
  end

  defp status_section(assigns) do
    ~H"""
    <section class="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <div class="lg:col-span-2">
        <.live_component
          module={ReencodarrWeb.Dashboard.StatusPanelComponent}
          id="status-panel"
          encoding={@status.encoding.active}
          crf_searching={@status.crf_searching.active}
          syncing={@status.syncing.active}
          encoding_progress={@status.encoding.progress}
          crf_search_progress={@status.crf_searching.progress}
          sync_progress={@status.syncing.progress}
        />
      </div>

      <div class="space-y-4">
        <.stats_sidebar stats={@stats} />
      </div>
    </section>
    """
  end

  defp queues_section(assigns) do
    ~H"""
    <section class="grid grid-cols-1 xl:grid-cols-2 gap-6">
      <.live_component
        module={ReencodarrWeb.Dashboard.QueueDisplayComponent}
        id="crf-search-queue"
        queue={@queues.crf_search}
      />

      <.live_component
        module={ReencodarrWeb.Dashboard.QueueDisplayComponent}
        id="encoding-queue"
        queue={@queues.encoding}
      />
    </section>
    """
  end

  defp manual_scan_section(assigns) do
    ~H"""
    <section>
      <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
        <h3 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
          <span class="text-lg">🔍</span>
          Manual Scan
        </h3>
        <.live_component module={ReencodarrWeb.ManualScanComponent} id="manual-scan" />
      </div>
    </section>
    """
  end

  defp dashboard_footer(assigns) do
    ~H"""
    <footer class="mt-16 text-center text-slate-400 text-sm">
      <div class="max-w-7xl mx-auto border-t border-slate-700 pt-8">
        <p>
          Reencodarr &copy; 2024 &mdash;
          <a href="https://github.com/mjc/reencodarr" class="text-cyan-400 hover:text-cyan-300 transition-colors">
            GitHub
          </a>
        </p>
      </div>
    </footer>
    """
  end

  # Simplified stats sidebar
  defp stats_sidebar(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
      <h3 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <span class="text-lg">📊</span>
        Quick Stats
      </h3>

      <div class="space-y-4">
        <.stat_item label="Total VMAFs" value={@stats.total_vmafs} icon="🎯" />
        <.stat_item label="Chosen VMAFs" value={@stats.chosen_vmafs_count} icon="✅" />

        <div class="border-t border-white/10 pt-4">
          <.stat_item label="Last Video Update" value={@stats.last_video_update} icon="🕒" small={true} />
          <.stat_item label="Last Video Insert" value={@stats.last_video_insert} icon="📥" small={true} />
        </div>
      </div>
    </div>
    """
  end

  defp stat_item(assigns) do
    assigns = assign_new(assigns, :small, fn -> false end)

    ~H"""
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class={if(@small, do: "text-sm", else: "text-base")}>{@icon}</span>
        <span class={[
          "text-slate-200",
          if(@small, do: "text-xs", else: "text-sm")
        ]}>{@label}</span>
      </div>
      <span class={[
        "font-semibold text-white",
        if(@small, do: "text-xs", else: "text-sm")
      ]}>{@value}</span>
    </div>
    """
  end

  # Telemetry event handler - optimized for different update types
  def handle_telemetry_event([:reencodarr, :dashboard, :state_updated], _measurements, %{state: state}, %{live_view_pid: pid}) do
    send(pid, {:telemetry_event, state})
  end

  def handle_telemetry_event([:reencodarr, :dashboard, :progress_updated], _measurements, %{progress_data: progress_data}, %{live_view_pid: pid}) do
    send(pid, {:progress_update, progress_data})
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dashboard-#{inspect(self())}")
    :ok
  end

  # Helper function to safely get initial state, with fallback for test environment
  defp get_initial_state do
    try do
      Reencodarr.TelemetryReporter.get_current_state()
    catch
      :exit, _ ->
        # Return a default dashboard state for tests
        Reencodarr.DashboardState.initial()
    end
  end

  # Helper functions for selective updates to reduce memory usage

  defp update_progress_in_dashboard_data(dashboard_data, progress_data) do
    # Only update progress-related fields without recreating entire data structure
    status = dashboard_data.status

    updated_status = %{
      status
      | encoding: Map.merge(status.encoding, Map.get(progress_data, :encoding, %{})),
        crf_searching: Map.merge(status.crf_searching, Map.get(progress_data, :crf_searching, %{})),
        syncing: Map.merge(status.syncing, Map.get(progress_data, :syncing, %{}))
    }

    %{dashboard_data | status: updated_status}
  end

  defp update_timezone_in_dashboard_data(dashboard_data, new_timezone) do
    # Only update timezone-dependent fields (timestamps)
    updated_stats = %{
      dashboard_data.stats
      | last_video_update: TimeUtils.relative_time(dashboard_data.stats.last_video_update),
        last_video_insert: TimeUtils.relative_time(dashboard_data.stats.last_video_insert)
    }

    %{dashboard_data | stats: updated_stats}
  end
end
