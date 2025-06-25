defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Attach telemetry handler for dashboard state updates
    if connected?(socket) do
      :telemetry.attach_many(
        "dashboard-#{inspect(self())}",
        [[:reencodarr, :dashboard, :state_updated]],
        &__MODULE__.handle_telemetry_event/4,
        %{live_view_pid: self()}
      )
    end

    initial_state = Reencodarr.TelemetryReporter.get_current_state()

    socket =
      assign(socket,
        state: initial_state,
        timezone: socket.assigns[:timezone] || "UTC"
      )

    {:ok, socket}
  end

  @impl true
  def handle_info({:telemetry_event, state}, socket) do
    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    Logger.debug("Setting timezone to #{tz}")
    {:noreply, assign(socket, :timezone, tz)}
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
      class="min-h-screen bg-gray-900 flex flex-col items-center justify-start space-y-12 p-8"
      phx-hook="TimezoneHook"
    >
      <header class="w-full max-w-6xl flex flex-col md:flex-row items-center justify-between mb-12">
        <div>
          <h1 class="text-5xl font-extrabold text-indigo-400 tracking-tight drop-shadow-lg">
            Reencodarr Dashboard
          </h1>
          <p class="text-gray-300 mt-4 text-lg">
            Monitor and control your encoding pipeline in real time.
          </p>
        </div>

        <div class="flex flex-col md:flex-row items-center space-y-4 md:space-y-0 md:space-x-6 mt-4 md:mt-0">
          <div class="flex flex-wrap gap-4">
            <.render_control_buttons
              encoding={@state.encoding}
              crf_searching={@state.crf_searching}
              syncing={@state.syncing}
            />
          </div>
        </div>
      </header>

      <.live_component
        module={ReencodarrWeb.SummaryRowComponent}
        id="summary-row"
        stats={@state.stats}
      />

      <.render_manual_scan_form />

      <div class="w-full max-w-6xl grid grid-cols-1 md:grid-cols-3 gap-12">
        <.live_component
          module={ReencodarrWeb.QueueInformationComponent}
          id="queue-information"
          stats={@state.stats}
        />

        <.live_component
          module={ReencodarrWeb.ProgressInformationComponent}
          id="progress-information"
          sync_progress={@state.sync_progress}
          encoding_progress={@state.encoding_progress}
          crf_search_progress={@state.crf_search_progress}
        />

        <.live_component
          module={ReencodarrWeb.StatisticsComponent}
          id="statistics"
          stats={@state.stats}
          timezone={@timezone}
        />
      </div>

      <div class="w-full max-w-6xl grid grid-cols-1 md:grid-cols-2 gap-12">
        <.live_component
          module={ReencodarrWeb.CrfSearchQueueComponent}
          id="crf-search-queue"
          files={@state.next_crf_search}
        />

        <.live_component
          module={ReencodarrWeb.EncodeQueueComponent}
          id="encoding-queue"
          files={@state.videos_by_estimated_percent}
        />
      </div>

      <footer class="w-full max-w-6xl mt-16 text-center text-xs text-gray-500 border-t border-gray-700 pt-6">
        Reencodarr &copy; 2024 &mdash;
        <a href="https://github.com/mjc/reencodarr" class="underline hover:text-indigo-400">GitHub</a>
      </footer>
    </div>
    """
  end

  # Control Buttons
  def render_control_buttons(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.ControlButtonsComponent}
      id="control-buttons"
      encoding={@encoding}
      crf_searching={@crf_searching}
      syncing={@syncing}
    />
    """
  end

  # Manual Scan Form
  def render_manual_scan_form(assigns) do
    ~H"""
    <.live_component module={ReencodarrWeb.ManualScanComponent} id="manual-scan" />
    """
  end

  # Telemetry event handler
  def handle_telemetry_event([:reencodarr, :dashboard, :state_updated], _measurements, %{state: state}, %{live_view_pid: pid}) do
    send(pid, {:telemetry_event, state})
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dashboard-#{inspect(self())}")
    :ok
  end

  # LiveView callbacks
end
