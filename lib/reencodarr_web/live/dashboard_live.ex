defmodule ReencodarrWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard for monitoring and controlling the encoding pipeline.
  """

  use ReencodarrWeb, :live_view
  alias Reencodarr.{Encoder, CrfSearcher, Statistics, Sync, ManualScanner}
  require Logger

  # --- Default Assigns ---
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

  # --- LiveView Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Reencodarr.PubSub, "stats")

    socket =
      socket
      |> assign_defaults()
      |> assign_new(:timezone, fn -> "UTC" end)

    # Fetch stats asynchronously
    if connected?(socket), do: send(self(), :load_stats)

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_stats, socket) do
    stats = Statistics.get_stats()
    {:noreply, assign_stats(socket, stats)}
  end


  @impl true
  def handle_info({:encoder, status}, socket) when status in [:started, :paused] do
    Logger.debug("Encoder #{status}")
    {:noreply, assign(socket, :encoding, status == :started)}
  end

  @impl true
  def handle_info({:crf_searcher, status}, socket) when status in [:started, :paused] do
    Logger.debug("CRF search #{status}")
    {:noreply, assign(socket, :crf_searching, status == :started)}
  end

  @impl true
  def handle_info(:sync_complete, socket) do
    Logger.info("Sync complete")
    {:noreply, assign(socket, syncing: false, sync_progress: 0)}
  end

  @impl true
  def handle_info({:sync_progress, progress}, socket) do
    Logger.debug("Sync progress: #{inspect(progress)}")
    {:noreply, assign(socket, syncing: true, sync_progress: progress)}
  end

  @impl true
  def handle_info({:stats, new_stats}, socket) do
    Logger.debug("Received new stats: #{inspect(new_stats)}")

    default_stats = %{
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

    default_encoding_progress = %{filename: :none, percent: 0, fps: 0, eta: ""}
    default_crf_search_progress = %{filename: :none, crf: nil, percent: 0, score: nil}
    merged_stats = Map.merge(default_stats, new_stats.stats || %{})

    merged_encoding_progress =
      Map.merge(default_encoding_progress, new_stats.encoding_progress || %{})

    merged_crf_search_progress =
      Map.merge(default_crf_search_progress, new_stats.crf_search_progress || %{})

    {:noreply,
     socket
     |> assign(:stats, merged_stats)
     |> assign(:encoding, new_stats.encoding)
     |> assign(:crf_searching, new_stats.crf_searching)
     |> assign(:syncing, new_stats.syncing)
     |> assign(:sync_progress, new_stats.sync_progress)
     |> assign(:crf_search_progress, merged_crf_search_progress)
     |> assign(:encoding_progress, merged_encoding_progress)}
  end

  @impl true
  def handle_info({:encoding, :none}, socket) do
    # Clear encoding progress when encoding completes
    {:noreply, assign(socket, :encoding_progress, %Reencodarr.Statistics.EncodingProgress{})}
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
  def handle_info({:crf_search, :none}, socket) do
    # Clear CRF search progress when CRF search completes
    {:noreply, assign(socket, :crf_search_progress, %Reencodarr.Statistics.CrfSearchProgress{})}
  end

  @impl true
  def handle_info({:crf_search, progress}, socket) do
    Logger.debug("Received CRF search progress: #{inspect(progress)}")

    {:noreply, assign(socket, :crf_search_progress, progress)}
  end

  # --- Handle Events ---

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    Logger.debug("Setting timezone to #{tz}")
    {:noreply, assign(socket, :timezone, tz)}
  end

  @impl true
  def handle_event("toggle", %{"target" => "encoder"}, socket) do
    toggle_app(Encoder, :encoding, socket)
  end

  @impl true
  def handle_event("toggle", %{"target" => "crf_search"}, socket) do
    toggle_app(CrfSearcher, :crf_searching, socket)
  end

  @impl true
  def handle_event("sync", %{"target" => "sonarr"}, socket) do
    Logger.info("Syncing with sonarr")
    Sync.sync_episodes()
    {:noreply, assign(socket, syncing: true, sync_progress: 0)}
  end

  @impl true
  def handle_event("sync", %{"target" => "radarr"}, socket) do
    Logger.info("Syncing with radarr")
    Sync.sync_movies()
    {:noreply, assign(socket, syncing: true, sync_progress: 0)}
  end

  @impl true
  def handle_event("manual_scan", %{"path" => path}, socket) do
    Logger.info("Starting manual scan for path: #{path}")
    ManualScanner.scan(path)
    {:noreply, socket}
  end

  defp toggle_app(app, state_key, socket) do
    new_state = not socket.assigns[state_key]
    Logger.info("#{state_key} #{if new_state, do: "started", else: "paused"}")
    if new_state, do: app.start(), else: app.pause()
    {:noreply, assign(socket, state_key, new_state)}
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
            <.render_control_buttons {assigns} />
          </div>
        </div>
      </header>

      <.render_summary_row stats={@stats} />

      <.render_manual_scan_form />

      <div class="w-full max-w-6xl grid grid-cols-1 md:grid-cols-3 gap-8">
        <.render_queue_information stats={@stats} />
        <.render_progress_information
          sync_progress={@sync_progress}
          encoding_progress={@encoding_progress}
          crf_search_progress={@crf_search_progress}
        />
        <.render_statistics stats={@stats} timezone={@timezone} />
      </div>

      <footer class="w-full max-w-6xl mt-12 text-center text-xs text-gray-500 border-t border-gray-700 pt-4">
        Reencodarr &copy; 2024 &mdash;
        <a href="https://github.com/mjc/reencodarr" class="underline hover:text-indigo-400">GitHub</a>
      </footer>
    </div>
    """
  end

  # --- Private Helpers ---

  defp human_readable_time(nil, _timezone), do: "N/A"

  defp human_readable_time(datetime, timezone) do
    tz =
      cond do
        is_binary(timezone) and timezone != "" -> timezone
        true -> "UTC"
      end

    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.shift_zone!(tz)
    |> relative_time()
  end

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff} second(s) ago"
      diff < 3600 -> "#{div(diff, 60)} minute(s) ago"
      diff < 86400 -> "#{div(diff, 3600)} hour(s) ago"
      true -> "#{div(diff, 86400)} day(s) ago"
    end
  end

  defp parse_integer(value) do
    Integer.parse(to_string(value)) |> elem(0)
  end

  # --- Assign Helpers ---

  defp assign_defaults(socket) do
    socket
    |> assign(:stats, @default_stats)
    |> assign(:encoding, false)
    |> assign(:crf_searching, false)
    |> assign(:syncing, false)
    |> assign(:sync_progress, 0)
    |> assign(:crf_search_progress, @default_crf_search_progress)
    |> assign(:encoding_progress, @default_encoding_progress)
  end

  defp assign_stats(socket, stats) do
    merged_stats = Map.merge(@default_stats, stats.stats || %{})

    merged_encoding_progress =
      Map.merge(@default_encoding_progress, stats.encoding_progress || %{})

    merged_crf_search_progress =
      Map.merge(@default_crf_search_progress, stats.crf_search_progress || %{})

    socket
    |> assign(:stats, merged_stats)
    |> assign(:encoding, stats.encoding)
    |> assign(:crf_searching, stats.crf_searching)
    |> assign(:syncing, stats.syncing)
    |> assign(:sync_progress, stats.sync_progress)
    |> assign(:crf_search_progress, merged_crf_search_progress)
    |> assign(:encoding_progress, merged_encoding_progress)
  end

  # --- Render Helpers ---

  defp render_summary_row(assigns) do
    ~H"""
    <div class="w-full max-w-6xl grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
      <div class="bg-indigo-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-indigo-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path d="M9 17v-2a4 4 0 1 1 8 0v2"></path>
          <circle cx="12" cy="7" r="4"></circle>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.total_videos}</div>
          <div class="text-xs text-indigo-100">Total Videos</div>
        </div>
      </div>
      <div class="bg-green-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-green-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path d="M5 13l4 4L19 7"></path>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.reencoded}</div>
          <div class="text-xs text-green-100">Reencoded</div>
        </div>
      </div>
      <div class="bg-yellow-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-yellow-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <circle cx="12" cy="12" r="10"></circle>
          <path d="M12 8v4l3 3"></path>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.not_reencoded}</div>
          <div class="text-xs text-yellow-100">Not Reencoded</div>
        </div>
      </div>
      <div class="bg-blue-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-blue-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <rect width="20" height="14" x="2" y="5" rx="2"></rect>
          <path d="M2 10h20"></path>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.queue_length.encodes}</div>
          <div class="text-xs text-blue-100">Encodes in Queue</div>
        </div>
      </div>
    </div>
    """
  end

  defp render_manual_scan_form(assigns) do
    ~H"""
    <div class="w-full max-w-2xl flex justify-center mb-6">
      <form phx-submit="manual_scan" class="flex items-center space-x-2 w-full">
        <input
          type="text"
          name="path"
          placeholder="Enter path to scan"
          class="input px-4 py-2 rounded shadow border border-gray-600 dark:border-gray-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 w-full bg-gray-900 text-gray-100"
        />
        <button
          type="submit"
          class="text-white font-bold py-2 px-4 rounded shadow bg-indigo-500 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500"
        >
          Start Manual Scan
        </button>
      </form>
    </div>
    """
  end

  defp render_queue_information(assigns) do
    ~H"""
    <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
      <h2 class="text-lg font-bold mb-4 text-indigo-300 flex items-center space-x-2">
        <svg
          class="w-5 h-5 text-indigo-400"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <rect width="20" height="14" x="2" y="5" rx="2"></rect>
          <path d="M2 10h20"></path>
        </svg>
        <span>Queue Information</span>
      </h2>
      <div class="flex flex-col space-y-4">
        <.render_queue_info stats={@stats} />
      </div>
    </div>
    """
  end

  defp render_progress_information(assigns) do
    ~H"""
    <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
      <h2 class="text-lg font-bold mb-4 text-green-300 flex items-center space-x-2">
        <svg
          class="w-5 h-5 text-green-400"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path d="M3 12h18"></path>
          <path d="M12 3v18"></path>
        </svg>
        <span>Progress Information</span>
      </h2>
      <div class="flex flex-col space-y-4">
        <.render_encoding_progress encoding_progress={@encoding_progress} />
        <.render_crf_search_progress crf_search_progress={@crf_search_progress} />
        <.render_sync_progress sync_progress={@sync_progress} />
      </div>
    </div>
    """
  end

  defp render_statistics(assigns) do
    ~H"""
    <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
      <h2 class="text-lg font-bold mb-4 text-pink-300 flex items-center space-x-2">
        <svg
          class="w-5 h-5 text-pink-400"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <circle cx="12" cy="12" r="10"></circle>
        </svg>
        <span>Statistics</span>
      </h2>
      <div class="flex flex-col space-y-4">
        <div class="flex items-center justify-between group">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
            <span>Most Recent Video Update</span>
            <span
              class="ml-1 text-xs text-gray-400 group-hover:underline cursor-help"
              title="Last time any video was updated in the database."
            >
              ?
            </span>
          </div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {human_readable_time(@stats.most_recent_video_update, @timezone)}
          </div>
        </div>
        <div class="flex items-center justify-between group">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
            <span>Most Recent Inserted Video</span>
            <span
              class="ml-1 text-xs text-gray-400 group-hover:underline cursor-help"
              title="Last time a new video was added."
            >
              ?
            </span>
          </div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {human_readable_time(@stats.most_recent_inserted_video, @timezone)}
          </div>
        </div>
        <div class="flex items-center justify-between">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">Total VMAFs</div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {@stats.total_vmafs}
          </div>
        </div>
        <div class="flex items-center justify-between">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">Chosen VMAFs Count</div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {@stats.chosen_vmafs_count}
          </div>
        </div>
        <div class="flex items-center justify-between group">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
            <span>Lowest Chosen VMAF %</span>
            <span
              class="ml-1 text-xs text-gray-400 group-hover:underline cursor-help"
              title="Lowest VMAF percentage chosen for any video."
            >
              ?
            </span>
          </div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {@stats.lowest_vmaf.percent}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_control_buttons(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <button
        phx-click="toggle"
        phx-value-target="encoder"
        class={"flex items-center space-x-2 px-4 py-2 rounded-lg shadow font-semibold focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @encoding, do: "bg-red-500 hover:bg-red-600 focus:ring-red-500", else: "bg-indigo-500 hover:bg-indigo-600 focus:ring-indigo-500"}
        title={if @encoding, do: "Pause Encoder", else: "Start Encoder"}
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <%= if @encoding do %>
            <rect x="6" y="4" width="4" height="16" rx="1" />
            <rect x="14" y="4" width="4" height="16" rx="1" />
          <% else %>
            <polygon points="5,3 19,12 5,21 5,3" />
          <% end %>
        </svg>
        <span>{(@encoding && "Pause Encoder") || "Start Encoder"}</span>
      </button>
      <button
        phx-click="toggle"
        phx-value-target="crf_search"
        class={"flex items-center space-x-2 px-4 py-2 rounded-lg shadow font-semibold focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @crf_searching, do: "bg-red-500 hover:bg-red-600 focus:ring-red-500", else: "bg-green-500 hover:bg-green-600 focus:ring-green-500"}
        title={if @crf_searching, do: "Pause CRF Search", else: "Start CRF Search"}
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <%= if @crf_searching do %>
            <rect x="6" y="4" width="4" height="16" rx="1" />
            <rect x="14" y="4" width="4" height="16" rx="1" />
          <% else %>
            <polygon points="5,3 19,12 5,21 5,3" />
          <% end %>
        </svg>
        <span>{(@crf_searching && "Pause CRF Search") || "Start CRF Search"}</span>
      </button>
      <button
        phx-click="sync"
        phx-value-target="sonarr"
        class={"flex items-center space-x-2 font-semibold px-4 py-2 rounded-lg shadow focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @syncing, do: "bg-gray-500 focus:ring-gray-500 cursor-not-allowed", else: "bg-yellow-500 hover:bg-yellow-600 focus:ring-yellow-500"}
        disabled={@syncing}
        title="Sync Sonarr"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <path d="M4 4v5h.582M20 20v-5h-.581M5 9A7 7 0 0 1 19 15M19 15V9M5 9v6" />
        </svg>
        <span>Sync Sonarr</span>
      </button>
      <button
        phx-click="sync"
        phx-value-target="radarr"
        class={"flex items-center space-x-2 font-semibold px-4 py-2 rounded-lg shadow focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @syncing, do: "bg-gray-500 focus:ring-gray-500 cursor-not-allowed", else: "bg-green-500 hover:bg-green-600 focus:ring-green-500"}
        disabled={@syncing}
        title="Sync Radarr"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <path d="M4 4v5h.582M20 20v-5h-.581M5 9A7 7 0 0 1 19 15M19 15V9M5 9v6" />
        </svg>
        <span>Sync Radarr</span>
      </button>
    </div>
    """
  end

  defp render_queue_info(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
        <span>CRF Searches in Queue</span>
        <span class="ml-1 text-xs text-gray-400" title="Number of CRF search jobs waiting.">?</span>
      </div>
      <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
        {@stats.queue_length.crf_searches}
      </div>
    </div>
    <div class="flex items-center justify-between">
      <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
        <span>Encodes in Queue</span>
        <span class="ml-1 text-xs text-gray-400" title="Number of encoding jobs waiting.">?</span>
      </div>
      <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
        {@stats.queue_length.encodes}
      </div>
    </div>
    """
  end

  defp render_encoding_progress(assigns) do
    ~H"""
    <div>
      <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 mb-1">Encoding Progress</div>
      <%= if @encoding_progress.filename != :none do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">Encoding:</span>
          <span class="font-mono">{@encoding_progress.filename}</span>
        </div>
        <div class="flex items-center space-x-2 mb-1">
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            <strong>
              {parse_integer(@encoding_progress.percent)}%
            </strong>
          </div>
        </div>
        <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
          <ul class="list-disc pl-5 fancy-list">
            <li>FPS: <strong>{@encoding_progress.fps}</strong></li>
            <li>ETA: <strong>{@encoding_progress.eta}</strong></li>
          </ul>
        </div>
        <div class="w-full bg-gray-600 dark:bg-gray-500 rounded-full h-2.5 mb-2">
          <div
            class="bg-indigo-600 h-2.5 rounded-full transition-all duration-300"
            style={"width: #{parse_integer(@encoding_progress.percent)}%"}
          >
          </div>
        </div>
      <% else %>
        <div class="text-sm leading-5 text-gray-400 dark:text-gray-300">
          No encoding in progress
        </div>
      <% end %>
    </div>
    """
  end

  defp render_crf_search_progress(assigns) do
    ~H"""
    <div>
      <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 mb-1">
        CRF Search Progress
      </div>
      <%= if @crf_search_progress.filename != :none do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">{@crf_search_progress.filename}</span>
        </div>
        <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
          <ul class="list-disc pl-5 fancy-list">
            <li>CRF: <strong>{@crf_search_progress.crf}</strong></li>
            <li>
              Percent: <strong>{@crf_search_progress.percent}%</strong> (of original size)
            </li>
            <li>VMAF Score: <strong>{@crf_search_progress.score}</strong> (Target: 95)</li>
          </ul>
        </div>
      <% else %>
        <div class="text-sm leading-5 text-gray-400 dark:text-gray-300">
          No CRF search in progress
        </div>
      <% end %>
    </div>
    """
  end

  defp render_sync_progress(assigns) do
    ~H"""
    <div>
      <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 mb-1">Sync Progress</div>
      <div class="flex items-center space-x-2">
        <div class="w-full bg-gray-600 rounded-full h-2.5 dark:bg-gray-500">
          <div
            class="bg-indigo-600 h-2.5 rounded-full transition-all duration-300"
            style={"width: #{if @sync_progress > 0, do: @sync_progress, else: 0}%"}
          >
          </div>
        </div>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
          <strong>{@sync_progress}%</strong>
        </div>
      </div>
    </div>
    """
  end
end
