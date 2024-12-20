defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Encoder, CrfSearcher, Statistics, Sync, ManualScanner}
  import Phoenix.LiveComponent

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Reencodarr.PubSub, "stats")

    {:ok,
     socket
     |> assign(Statistics.get_stats())
     |> assign(:timezone, "UTC")}
  end

  @impl true
  def handle_info(:update_stats, socket) do
    new_stats = Statistics.get_stats()
    {:noreply, assign(socket, new_stats)}
  end

  @impl true
  def handle_info({:progress, vmaf}, socket) do
    Logger.debug("Received progress event for VMAF: #{inspect(vmaf)}")
    {:noreply, assign(socket, :crf_search_progress, vmaf)}
  end

  @impl true
  def handle_info({:encoder, :started}, socket) do
    Logger.debug("Encoder started")
    {:noreply, assign(socket, :encoding, true)}
  end

  @impl true
  def handle_info({:encoder, :paused}, socket) do
    Logger.debug("Encoder paused")
    {:noreply, assign(socket, :encoding, false)}
  end

  @impl true
  def handle_info({:crf_searcher, :started}, socket) do
    Logger.debug("CRF search started")
    {:noreply, assign(socket, :crf_searching, true)}
  end

  @impl true
  def handle_info({:crf_searcher, :paused}, socket) do
    Logger.debug("CRF search paused")
    {:noreply, assign(socket, :crf_searching, false)}
  end

  @impl true
  def handle_info(:sync_complete, socket) do
    Logger.info("Sync complete")
    {:noreply, assign(socket, :syncing, false) |> assign(:sync_progress, 0)}
  end

  @impl true
  def handle_info({:sync_progress, progress}, socket) do
    Logger.debug("Sync progress: #{inspect(progress)}")
    {:noreply, assign(socket, :syncing, true) |> assign(:sync_progress, progress)}
  end

  @impl true
  def handle_info({:stats, new_stats}, socket) do
    Logger.debug("Received new stats: #{inspect(new_stats)}")

    socket =
      socket
      |> assign(:encoding, new_stats.encoding)
      |> assign(:crf_searching, new_stats.crf_searching)
      |> assign(:syncing, new_stats.syncing)
      |> assign(:sync_progress, new_stats.sync_progress)
      |> assign(:stats, new_stats.stats)
      |> assign(:crf_search_progress, new_stats.crf_search_progress)
      |> assign(:encoding_progress, new_stats.encoding_progress)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:encoding, :none}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:encoding, progress}, socket) do
    Logger.debug("Received encoding progress: #{inspect(progress)}")

    Logger.info(
      "Encoding progress: #{progress.percent}% ETA: #{progress.eta} FPS: #{progress.fps}"
    )

    {:noreply, assign(socket, :encoding_progress, progress)}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
    Logger.debug("Setting timezone to #{timezone}")
    {:noreply, assign(socket, :timezone, timezone)}
  end

  @impl true
  def handle_event("toggle_encoder", _params, socket) do
    if socket.assigns.encoding do
      Encoder.pause()
      Logger.info("Encoder paused")
      {:noreply, assign(socket, :encoding, false)}
    else
      Encoder.start()
      Logger.info("Encoder started")
      {:noreply, assign(socket, :encoding, true)}
    end
  end

  @impl true
  def handle_event("toggle_crf_search", _params, socket) do
    if socket.assigns.crf_searching do
      CrfSearcher.pause()
      Logger.info("CRF search paused")
      {:noreply, assign(socket, :crf_searching, false)}
    else
      CrfSearcher.start()
      Logger.info("CRF search started")
      {:noreply, assign(socket, :crf_searching, true)}
    end
  end

  @impl true
  def handle_event("sync_sonarr", _params, socket) do
    Logger.info("Syncing with Sonarr (slow)")
    socket = assign(socket, :syncing, true) |> assign(:sync_progress, 0)
    Sync.sync_episode_files()
    {:noreply, socket}
  end

  @impl true
  def handle_event("sync_radarr", _params, socket) do
    Logger.info("Syncing with Radarr (slow)")
    socket = assign(socket, :syncing, true) |> assign(:sync_progress, 0)
    Sync.sync_movie_files()
    {:noreply, socket}
  end

  @impl true
  def handle_event("manual_scan", %{"path" => path}, socket) do
    Logger.info("Starting manual scan for path: #{path}")
    ManualScanner.scan(path)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="dashboard-live"
      class="min-h-screen bg-gray-100 dark:bg-gray-900 flex flex-col items-center justify-center space-y-8"
      phx-hook="TimezoneHook"
    >
      <div class="w-full flex justify-between items-center mb-4 px-4">
        <.live_component
          module={ReencodarrWeb.ToggleComponent}
          id="toggle-encoder"
          toggle_event="toggle_encoder"
          active={@encoding}
          active_text="Pause Encoder"
          inactive_text="Start Encoder"
          active_class="bg-red-500"
          inactive_class="bg-blue-500"
        />
        <button
          phx-click="sync_sonarr"
          class={"text-white font-bold py-2 px-4 rounded " <> if @syncing, do: "bg-gray-500", else: "bg-yellow-500 hover:bg-yellow-700"}
        >
          Sync Sonarr (slow)
        </button>
        <button
          phx-click="sync_radarr"
          class={"text-white font-bold py-2 px-4 rounded " <> if @syncing, do: "bg-gray-500", else: "bg-green-500 hover:bg-green-700"}
        >
          Sync Radarr (slow)
        </button>
        <.live_component
          module={ReencodarrWeb.ToggleComponent}
          id="toggle-crf-search"
          toggle_event="toggle_crf_search"
          active={@crf_searching}
          active_text="Pause CRF Search"
          inactive_text="Start CRF Search"
          active_class="bg-red-500"
          inactive_class="bg-green-500"
        />
        <div>
          <form phx-submit="manual_scan">
            <input type="text" name="path" placeholder="Enter path to scan" class="input" />
            <button
              type="submit"
              class="text-white font-bold py-2 px-4 rounded bg-blue-500 hover:bg-blue-700"
            >
              Start Manual Scan
            </button>
          </form>
        </div>
      </div>

      <div class="w-full grid grid-cols-1 md:grid-cols-2 gap-4 px-4">
        <.live_component
          module={ReencodarrWeb.QueueComponent}
          id="queue-component"
          queue_length={@stats.queue_length}
        />
        <.live_component
          module={ReencodarrWeb.ProgressComponent}
          id="progress-component"
          progress={@encoding_progress}
          vmaf={@crf_search_progress}
          sync_progress={@sync_progress}
        />
        <.live_component
          module={ReencodarrWeb.StatsComponent}
          id="stats-component"
          stats={@stats}
          timezone={@timezone}
        />
      </div>
    </div>
    """
  end
end
