defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Statistics

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Group PubSub topics and document their purpose
    # Subscribe to relevant topics
    if connected?(socket), do: Phoenix.PubSub.subscribe(Reencodarr.PubSub, "stats")

    # fetch current stats and build initial struct state
    fetched = Statistics.get_stats()

    initial_state = %Statistics{
      fetched
      | crf_searching: Reencodarr.CrfSearcher.running?(),
        encoding: Reencodarr.Encoder.running?()
    }

    socket =
      assign(socket,
        state: initial_state,
        timezone: socket.assigns[:timezone] || "UTC"
      )

    {:ok, socket}
  end

  # helper to update nested DashboardState and re-assign
  defp update_state(socket, fun) do
    new_state = fun.(socket.assigns.state)
    assign(socket, :state, new_state)
  end

  @impl true
  def handle_info({:encoder, :started, filename}, socket) do
    Logger.debug("Encoder started for #{filename}")

    {:noreply,
     update_state(
       socket,
       &%Statistics{
         &1
         | encoding: true,
           encoding_progress: %Statistics.EncodingProgress{
             filename: filename,
             percent: 0,
             eta: 0,
             fps: 0
           }
       }
     )}
  end

  def handle_info({:encoder, status}, socket) when status in [:started, :paused] do
    Logger.debug("Encoder #{status}")

    {:noreply, update_state(socket, &%Statistics{&1 | encoding: status == :started})}
  end

  @impl true
  def handle_info({:crf_searcher, status}, socket) when status in [:started, :paused] do
    Logger.debug("CRF search #{status}")

    {:noreply, update_state(socket, &%Statistics{&1 | crf_searching: status == :started})}
  end

  @impl true
  def handle_info({:sync, :started}, socket) do
    Logger.info("Sync started")

    {:noreply, update_state(socket, &%Statistics{&1 | syncing: true, sync_progress: 0})}
  end

  @impl true
  def handle_info({:sync, :progress, progress}, socket) do
    Logger.debug("Sync progress: #{inspect(progress)}")

    {:noreply, update_state(socket, &%Statistics{&1 | sync_progress: progress})}
  end

  @impl true
  def handle_info({:sync, :complete}, socket) do
    Logger.info("Sync complete")

    {:noreply, update_state(socket, &%Statistics{&1 | syncing: false, sync_progress: 0})}
  end

  # Add documentation for PubSub topics
  @doc "Handles stats updates broadcasted via PubSub"
  # Handle PubSub messages
  @impl true
  def handle_info({:stats, state}, socket) do
    if is_map(state) do
      Logger.debug("Received stats update")
      {:noreply, assign(socket, :state, state)}
    else
      Logger.error("Invalid stats update received: #{inspect(state)}")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:encoding, :none}, socket) do
    # Clear encoding progress when encoding completes
    {:noreply,
     update_state(
       socket,
       &%Statistics{
         &1
         | encoding_progress: %Statistics.EncodingProgress{
             filename: :none,
             percent: 0,
             eta: 0,
             fps: 0
           }
       }
     )}
  end

  @impl true
  def handle_info({:encoding, progress}, socket) do
    Logger.debug("Received encoding progress: #{inspect(progress)}")

    Logger.info(
      "Encoding progress: #{progress.percent}% ETA: #{progress.eta} FPS: #{progress.fps}"
    )

    {:noreply, update_state(socket, &%Statistics{&1 | encoding_progress: progress})}
  end

  @impl true
  def handle_info({:crf_search, :none}, socket) do
    # Clear CRF search progress when CRF search completes
    {:noreply,
     update_state(socket, &%Statistics{&1 | crf_search_progress: %Statistics.CrfSearchProgress{}})}
  end

  @impl true
  def handle_info({:crf_search, progress}, socket) do
    Logger.debug("Received CRF search progress: #{inspect(progress)}")

    {:noreply, update_state(socket, &%Statistics{&1 | crf_search_progress: progress})}
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

  # Summary Row
  def render_summary_row(assigns) do
    ~H"""
    <.live_component module={ReencodarrWeb.SummaryRowComponent} id="summary-row" stats={@stats} />
    """
  end

  # Manual Scan Form
  def render_manual_scan_form(assigns) do
    ~H"""
    <.live_component module={ReencodarrWeb.ManualScanComponent} id="manual-scan" />
    """
  end

  def render_queue_information(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.QueueInformationComponent}
      id="queue-information"
      stats={@stats}
    />
    """
  end

  # Progress Information
  def render_progress_information(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.ProgressInformationComponent}
      id="progress-information"
      sync_progress={@sync_progress}
      encoding_progress={@encoding_progress}
      crf_search_progress={@crf_search_progress}
    />
    """
  end

  # Statistics
  def render_statistics(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.StatisticsComponent}
      id="statistics"
      stats={@stats}
      timezone={@timezone}
    />
    """
  end

  # Encoding Queue
  def render_encoding_queue(assigns) do
    ~H"""
    <table class="table-auto w-full border-collapse border border-gray-700">
      <thead>
        <tr>
          <th class="border border-gray-700 px-4 py-2 text-indigo-500">File Name</th>
          <th class="border border-gray-700 px-4 py-2 text-indigo-500">Bitrate (kbps)</th>
          <th class="border border-gray-700 px-4 py-2 text-indigo-500">Size (bytes)</th>
          <th class="border border-gray-700 px-4 py-2 text-indigo-500">Percent</th>
        </tr>
      </thead>
      <tbody>
        <%= for file <- @files do %>
          <tr class="hover:bg-gray-800 transition-colors duration-200">
            <td class="border border-gray-700 px-4 py-2 text-gray-300">
              {Path.basename(file.path)}
            </td>
            <td class="border border-gray-700 px-4 py-2 text-gray-300">
              {file.bitrate || "N/A"}
            </td>
            <td class="border border-gray-700 px-4 py-2 text-gray-300">
              {file.size || "N/A"}
            </td>
            <td class="border border-gray-700 px-4 py-2 text-gray-300">
              {file.percent || "N/A"}
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end
end
