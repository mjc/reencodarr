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

  defp stats_data(stats, timezone) do
    [
      {"Most Recent Video Update", human_readable_time(stats.most_recent_video_update, timezone)},
      # The most recent time a video was updated in the system.
      {"Most Recent Inserted Video",
       human_readable_time(stats.most_recent_inserted_video, timezone)},
      # The most recent time a new video was added to the system.
      {"Not Reencoded", stats.not_reencoded},
      # The number of videos that have not been reencoded.
      {"Reencoded", stats.reencoded},
      # The number of videos that have been reencoded.
      {"Total Videos", stats.total_videos},
      # The total number of videos in the system.
      {"Average VMAF Percentage", stats.avg_vmaf_percentage},
      # The average Video Multimethod Assessment Fusion (VMAF) score percentage across all videos.
      {"Lowest Chosen VMAF Percentage", stats.lowest_vmaf.percent},
      # The lowest VMAF score percentage chosen for reencoding.
      {"Total VMAFs", stats.total_vmafs},
      # The total number of VMAF scores calculated.
      {"Chosen VMAFs Count", stats.chosen_vmafs_count}
      # The number of VMAF scores that were chosen for reencoding.
    ]
  end

  defp human_readable_time(nil, _timezone), do: "N/A"

  defp human_readable_time(datetime, timezone) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.shift_zone!(timezone)
    |> relative_time()
  end

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 ->
        "#{diff} second(s) ago"

      diff < 3600 ->
        minutes = div(diff, 60)
        "#{minutes} minute(s) ago"

      diff < 86400 ->
        hours = div(diff, 3600)
        "#{hours} hour(s) ago"

      true ->
        days = div(diff, 86400)
        "#{days} day(s) ago"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="dashboard-live"
      class="min-h-screen bg-gray-900 dark:bg-gray-800 flex flex-col items-center justify-center space-y-8 p-6"
      phx-hook="TimezoneHook"
    >
      <div class="w-full flex justify-center mb-6">
        <form phx-submit="manual_scan" class="flex items-center space-x-2">
          <input
            type="text"
            name="path"
            placeholder="Enter path to scan"
            class="input px-4 py-2 rounded shadow border border-gray-600 dark:border-gray-700 focus:outline-none focus:ring-2 focus:ring-indigo-500"
          />
          <button
            type="submit"
            class="text-white font-bold py-2 px-4 rounded shadow bg-indigo-500 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500"
          >
            Start Manual Scan
          </button>
        </form>
      </div>

      <div class="w-full grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <!-- Queue Information -->
        <div class="w-full bg-gray-800 dark:bg-gray-700 rounded-lg shadow-lg p-4">
          <h2 class="text-lg font-bold mb-4 text-gray-200 dark:text-gray-300">Queue Information</h2>
          <div class="flex flex-col space-y-4">
            <div class="flex items-center justify-between">
              <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">
                CRF Searches in Queue
              </div>
              <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                {@stats.queue_length.crf_searches}
              </div>
            </div>
            <div class="flex items-center justify-between">
              <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">Encodes in Queue</div>
              <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                {@stats.queue_length.encodes}
              </div>
            </div>
          </div>
        </div>

        <!-- Progress Information -->
        <div class="w-full bg-gray-800 dark:bg-gray-700 rounded-lg shadow-lg p-4">
          <h2 class="text-lg font-bold mb-4 text-gray-200 dark:text-gray-300">
            Progress Information
          </h2>
          <div class="flex flex-col space-y-4">
            <div>
              <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">Encoding Progress</div>
              <%= if @encoding_progress.filename != :none do %>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                  Encoding: <strong>{@encoding_progress.filename}</strong>
                </div>
                <div class="flex items-center space-x-2">
                  <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                    <strong>
                      {Integer.parse(to_string(@encoding_progress.percent)) |> elem(0)}%
                    </strong>
                  </div>
                </div>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mt-2">
                  <ul class="list-disc pl-5 fancy-list">
                    <li>FPS: <strong>{@encoding_progress.fps}</strong></li>
                    <li>ETA: <strong>{@encoding_progress.eta}</strong></li>
                  </ul>
                </div>
                <div class="w-full bg-gray-600 dark:bg-gray-500 rounded-full h-2.5">
                  <div
                    class="bg-indigo-600 h-2.5 rounded-full"
                    style={"width: #{Integer.parse(to_string(@encoding_progress.percent)) |> elem(0)}%"}
                  >
                  </div>
                </div>
              <% else %>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                  No encoding in progress
                </div>
              <% end %>
            </div>
            <div>
              <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">
                CRF Search Progress
              </div>
              <%= if @crf_search_progress.filename != :none do %>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                  CRF Search: <strong>{@crf_search_progress.filename}</strong>
                </div>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                  <ul class="list-disc pl-5 fancy-list">
                    <li>CRF: <strong>{@crf_search_progress.crf}</strong></li>
                    <li>
                      Percent: <strong>{@crf_search_progress.percent}%</strong> (of original size)
                    </li>
                    <li>VMAF Score: <strong>{@crf_search_progress.score}</strong> (Target: 95)</li>
                  </ul>
                </div>
              <% else %>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                  No CRF search in progress
                </div>
              <% end %>
            </div>
            <div>
              <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">Sync Progress</div>
              <div class="flex items-center space-x-2">
                <div class="w-full bg-gray-600 rounded-full h-2.5 dark:bg-gray-500">
                  <div
                    class="bg-indigo-600 h-2.5 rounded-full"
                    style={"width: #{if @sync_progress > 0, do: @sync_progress, else: 0}%"}
                  >
                  </div>
                </div>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
                  <strong>{@sync_progress}%</strong>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Statistics -->
        <div class="w-full bg-gray-800 dark:bg-gray-700 rounded-lg shadow-lg p-4">
          <h2 class="text-lg font-bold mb-4 text-gray-200 dark:text-gray-300">Statistics</h2>
          <div class="flex flex-col space-y-4">
            <%= for {label, value} <- stats_data(@stats, @timezone) do %>
              <div class="flex items-center justify-between">
                <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">{label}</div>
                <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">{value}</div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <div class="w-full flex flex-wrap justify-between items-center mt-6 space-y-4 md:space-y-0">
        <div class="flex flex-wrap space-x-4">
          <button
            phx-click="toggle_encoder"
            class={"text-white px-4 py-2 rounded shadow focus:outline-none focus:ring-2 " <> if @encoding, do: "bg-red-500 focus:ring-red-500", else: "bg-indigo-500 focus:ring-indigo-500"}
          >
            {(@encoding && "Pause Encoder") || "Start Encoder"}
          </button>
          <button
            phx-click="toggle_crf_search"
            class={"text-white px-4 py-2 rounded shadow focus:outline-none focus:ring-2 " <> if @crf_searching, do: "bg-red-500 focus:ring-red-500", else: "bg-green-500 focus:ring-green-500"}
          >
            {(@crf_searching && "Pause CRF Search") || "Start CRF Search"}
          </button>
        </div>
        <div class="flex flex-wrap space-x-4">
          <button
            phx-click="sync_sonarr"
            class={"text-white font-bold py-2 px-4 rounded shadow focus:outline-none focus:ring-2 " <> if @syncing, do: "bg-gray-500 focus:ring-gray-500", else: "bg-yellow-500 hover:bg-yellow-700 focus:ring-yellow-500"}
          >
            Sync Sonarr (slow)
          </button>
          <button
            phx-click="sync_radarr"
            class={"text-white font-bold py-2 px-4 rounded shadow focus:outline-none focus:ring-2 " <> if @syncing, do: "bg-gray-500 focus:ring-gray-500", else: "bg-green-500 hover:bg-green-700 focus:ring-green-500"}
          >
            Sync Radarr (slow)
          </button>
        </div>
      </div>
    </div>
    """
  end
end
