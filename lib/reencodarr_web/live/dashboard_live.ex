defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view

  import ReencodarrWeb.DashboardComponents

  alias Reencodarr.Statistics

  require Logger

  @default_stats %{
    total_videos: 0,
    reencoded: 0,
    not_reencoded: 0,
    queue_length: %{encodes: 0, crf_searches: 0},
    most_recent_video_update: nil,
    most_recent_inserted_video: nil,
    total_vmafs: 0,
    chosen_vmafs_count: 0,
    lowest_vmaf: %{percent: 0}
  }

  @default_encoding_progress %{filename: :none, percent: 0, fps: 0, eta: ""}
  @default_crf_search_progress %{filename: :none, crf: nil, percent: 0, score: nil}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Reencodarr.PubSub, "stats")

    socket =
      socket
      |> assign_new(:state, fn ->
        %Statistics.State{
          stats: @default_stats,
          encoding: false,
          crf_searching: false,
          syncing: false,
          sync_progress: 0,
          crf_search_progress: @default_crf_search_progress,
          encoding_progress: @default_encoding_progress
        }
      end)
      |> assign_new(:timezone, fn -> "UTC" end)

    {:ok, socket}
  end

  @impl true
  def handle_info({:encoder, :started, filename}, socket) do
    Logger.debug("Encoder started for #{filename}")

    state =
      socket.assigns.state
      |> Map.put(:encoding, true)
      |> Map.put(:encoding_progress, %Reencodarr.Statistics.EncodingProgress{
        filename: filename,
        percent: 0,
        eta: 0,
        fps: 0
      })

    {:noreply, assign(socket, :state, state)}
  end

  def handle_info({:encoder, status}, socket) when status in [:started, :paused] do
    Logger.debug("Encoder #{status}")

    # Update state instead of old :encoding assign
    state = Map.put(socket.assigns.state, :encoding, status == :started)

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:crf_searcher, status}, socket) when status in [:started, :paused] do
    Logger.debug("CRF search #{status}")

    state = Map.put(socket.assigns.state, :crf_searching, status == :started)

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:sync, :complete}, socket) do
    Logger.info("Sync complete")

    state = socket.assigns.state |> Map.put(:syncing, false) |> Map.put(:sync_progress, 0)

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:sync, :progress, progress}, socket) do
    Logger.debug("Sync progress: #{inspect(progress)}")

    state = socket.assigns.state |> Map.put(:syncing, true) |> Map.put(:sync_progress, progress)

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:stats, new_stats}, socket) do
    Logger.debug("Received new stats: #{inspect(new_stats)}")
    {:noreply, assign(socket, :state, new_stats)}
  end

  @impl true
  def handle_info({:encoding, :none}, socket) do
    # Clear encoding progress when encoding completes
    state =
      Map.put(
        socket.assigns.state,
        :encoding_progress,
        %Reencodarr.Statistics.EncodingProgress{filename: :none, percent: 0, eta: 0, fps: 0}
      )

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:encoding, progress}, socket) do
    Logger.debug("Received encoding progress: #{inspect(progress)}")

    Logger.info(
      "Encoding progress: #{progress.percent}% ETA: #{progress.eta} FPS: #{progress.fps}"
    )

    state = Map.put(socket.assigns.state, :encoding_progress, progress)

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:crf_search, :none}, socket) do
    # Clear CRF search progress when CRF search completes
    state =
      Map.put(
        socket.assigns.state,
        :crf_search_progress,
        %Reencodarr.Statistics.CrfSearchProgress{}
      )

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:crf_search, progress}, socket) do
    Logger.debug("Received CRF search progress: #{inspect(progress)}")

    state = Map.put(socket.assigns.state, :crf_search_progress, progress)

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
      class="min-h-screen bg-gradient-to-br from-gray-900 via-gray-800 to-gray-900 flex flex-col items-center justify-start space-y-8 p-6"
      phx-hook="TimezoneHook"
    >
      <header class="w-full max-w-6xl flex flex-col md:flex-row items-center justify-between mb-8">
        <div>
          <h1 class="text-3xl font-extrabold text-indigo-400 tracking-tight drop-shadow-lg">
            Reencodarr Dashboard
          </h1>
          <p class="text-gray-300 mt-2 text-sm">
            Monitor and control your encoding pipeline in real time.
          </p>
        </div>

        <div class="flex flex-col md:flex-row items-center space-y-4 md:space-y-0 md:space-x-6 mt-4 md:mt-0">
          <div class="flex flex-wrap gap-2">
            <.render_control_buttons
              encoding={@state.encoding}
              crf_searching={@state.crf_searching}
              syncing={@state.syncing}
            />
          </div>
        </div>
      </header>

      <.render_summary_row stats={@state.stats} />

      <.render_manual_scan_form />

      <div class="w-full max-w-6xl grid grid-cols-1 md:grid-cols-3 gap-8">
        <.render_queue_information stats={@state.stats} />
        <.render_progress_information
          sync_progress={@state.sync_progress}
          encoding_progress={@state.encoding_progress}
          crf_search_progress={@state.crf_search_progress}
        />
        <.render_statistics stats={@state.stats} timezone={@timezone} />
      </div>

      <footer class="w-full max-w-6xl mt-12 text-center text-xs text-gray-500 border-t border-gray-700 pt-4">
        Reencodarr &copy; 2024 &mdash;
        <a href="https://github.com/mjc/reencodarr" class="underline hover:text-indigo-400">GitHub</a>
      </footer>
    </div>
    """
  end
end
