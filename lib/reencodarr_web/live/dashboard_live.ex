defmodule ReencodarrWeb.DashboardLive do
  @moduledoc """
  Dashboard with simplified 3-layer architecture.

  Service Layer -> PubSub -> LiveView

  This eliminates the complex telemetry chain and provides immediate updates.
  """
  use ReencodarrWeb, :live_view

  alias Reencodarr.CrfSearcher.Broadway, as: CrfSearcherBroadway
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Dashboard.State, as: DashboardState
  alias Reencodarr.Formatters

  require Logger

  # Producer modules mapped by service
  @producer_modules %{
    analyzer: Reencodarr.Analyzer.Broadway.Producer,
    crf_searcher: Reencodarr.CrfSearcher.Broadway.Producer,
    encoder: Reencodarr.Encoder.Broadway.Producer
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket, %{
        # Legacy progress tracking (kept for compatibility)
        crf_progress: :none,
        encoding_progress: :none,
        analyzer_progress: :none,
        analyzer_throughput: nil,
        # Queue data
        queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
        queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
        # Service status
        service_status: get_optimistic_service_status(),
        # Sync status
        syncing: false,
        sync_progress: 0,
        service_type: nil,
        # New dashboard stats
        stats: Reencodarr.Media.get_default_stats(),
        # CRF Search active work
        crf_search_video: nil,
        crf_search_results: [],
        crf_search_sample: nil,
        # Encoding active work
        encoding_video: nil,
        encoding_vmaf: nil
      })

    # Setup subscriptions and processes if connected
    socket =
      if connected?(socket) do
        # Subscribe to dashboard events (for sync, analyzer, health alerts, etc.)
        Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
        # Subscribe to consolidated state changes from Dashboard.State
        Phoenix.PubSub.subscribe(Reencodarr.PubSub, DashboardState.state_channel())
        # Request current state immediately (subscribe-then-cast ensures ordering)
        GenServer.cast(DashboardState, :broadcast_state)

        # Request current status from all services with a small delay to let services initialize
        Process.send_after(self(), :request_status, 100)
        # Start periodic updates for queue counts and service status
        schedule_periodic_update()
        # Request throughput async
        request_analyzer_throughput()

        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # All handle_info callbacks grouped together

  # Consolidated state update from Dashboard.State (single source of truth).
  # Replaces independent handlers for encoding/CRF/service-status events.
  @impl true
  def handle_info({:dashboard_state_changed, state}, socket) do
    {:noreply,
     assign(socket,
       crf_search_video: state.crf_search_video,
       crf_search_results: state.crf_search_results,
       crf_search_sample: state.crf_search_sample,
       crf_progress: state.crf_progress,
       encoding_video: state.encoding_video,
       encoding_vmaf: state.encoding_vmaf,
       encoding_progress: state.encoding_progress,
       service_status: state.service_status,
       stats: state.stats,
       queue_counts: state.queue_counts,
       queue_items: state.queue_items
     )}
  end

  @impl true
  def handle_info({:analyzer_progress, data}, socket) do
    progress = %{
      percent: calculate_progress_percent(data),
      count: data[:current] || data[:count],
      total: data[:total],
      batch_size: data[:batch_size]
    }

    {:noreply, assign(socket, :analyzer_progress, progress)}
  end

  @impl true
  def handle_info({:batch_analysis_completed, data}, socket) do
    # Update analyzer progress to show completed batch info
    current_progress = socket.assigns.analyzer_progress

    progress =
      if current_progress != :none do
        Map.put(current_progress, :last_batch_size, data[:batch_size])
      else
        %{last_batch_size: data[:batch_size]}
      end

    {:noreply, assign(socket, :analyzer_progress, progress)}
  end

  # Encoder health alert handler
  @impl true
  def handle_info({:encoder_health_alert, data}, socket) do
    filename = if data.video_path, do: Path.basename(data.video_path), else: "unknown"

    message =
      case data.reason do
        :stalled_23_hours ->
          "Encoder may be stuck - no progress for 23+ hours (#{filename})"

        :killed_stuck_process ->
          "Killed stuck encoder after 24 hours of no progress (#{filename})"

        :reset_failed ->
          "Encoder reset failed - may need manual intervention (#{filename})"

        _ ->
          "Encoder health alert: #{inspect(data.reason)}"
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_info({:analyzer_throughput, data}, socket) do
    {:noreply, assign(socket, :analyzer_throughput, data.throughput || 0.0)}
  end

  # Test-specific event handlers
  @impl true
  def handle_info({:service_status, %{service: service, status: status}}, socket) do
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, service, status)
    {:noreply, assign(socket, :service_status, updated_status)}
  end

  @impl true
  def handle_info({:service_status, service, status}, socket)
      when is_atom(service) and is_atom(status) do
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, service, status)
    {:noreply, assign(socket, :service_status, updated_status)}
  end

  @impl true
  def handle_info({:queue_count, service, count}, socket) do
    current_counts = socket.assigns.queue_counts
    updated_counts = Map.put(current_counts, service, count)
    {:noreply, assign(socket, :queue_counts, updated_counts)}
  end

  @impl true
  def handle_info({:crf_progress, data}, socket) do
    progress = %{
      percent: calculate_progress_percent(data),
      filename: data[:filename],
      crf: data[:crf],
      score: data[:score]
    }

    {:noreply, assign(socket, :crf_progress, progress)}
  end

  @impl true
  def handle_info(:update_dashboard_data, socket) do
    # Request updated throughput async (don't block)
    request_analyzer_throughput()

    # Request fresh status from all pipelines
    request_current_status()

    # Schedule next update (recursive scheduling)
    schedule_periodic_update()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:request_status, socket) do
    # Request current status and retry a few times to ensure services respond
    request_current_status()
    # Schedule another status check in case services haven't responded yet
    Process.send_after(self(), :request_status_retry, 1000)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:request_status_retry, socket) do
    # Second attempt to get service status
    request_current_status()
    {:noreply, socket}
  end

  # Sync event handlers - simplified
  @impl true
  def handle_info({:sync_started, data}, socket) do
    socket = assign(socket, syncing: true, sync_progress: 0, service_type: data[:service_type])
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_progress, data}, socket) do
    progress = Map.get(data, :progress, 0)
    {:noreply, assign(socket, :sync_progress, progress)}
  end

  @impl true
  def handle_info({sync_event, data}, socket)
      when sync_event in [:sync_completed, :sync_failed] do
    socket = assign(socket, syncing: false, sync_progress: 0, service_type: nil)

    socket =
      if sync_event == :sync_failed do
        put_flash(socket, :error, "Sync failed: #{inspect(data[:error] || "Unknown error")}")
      else
        socket
      end

    {:noreply, socket}
  end

  # Catch-all: ignore events handled by Dashboard.State
  # (encoding_*, crf_search_*, pipeline state changes, etc.)
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("sync_sonarr", _params, socket) do
    if socket.assigns.syncing do
      {:noreply, put_flash(socket, :error, "Sync already in progress")}
    else
      Task.start(&Reencodarr.Sync.sync_episodes/0)
      {:noreply, put_flash(socket, :info, "Sonarr sync started")}
    end
  end

  @impl true
  def handle_event("sync_radarr", _params, socket) do
    if socket.assigns.syncing do
      {:noreply, put_flash(socket, :error, "Sync already in progress")}
    else
      Task.start(&Reencodarr.Sync.sync_movies/0)
      {:noreply, put_flash(socket, :info, "Radarr sync started")}
    end
  end

  @impl true
  def handle_event("sync_" <> service, _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown sync service: #{service}")}
  end

  # Row 1: Stats Bar Component
  attr :stats, :map, required: true
  attr :service_status, :map, required: true

  defp stats_bar(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-6 gap-4">
      <.stat_box
        label="Total Videos"
        value={format_number(@stats && @stats.total_videos)}
        sublabel="tracked"
      />
      <.stat_box
        label="Completed"
        value={format_completed(@stats)}
        sublabel="encoded"
      />
      <.stat_box
        label="Space Saved"
        value={format_savings(@stats && @stats.total_savings_gb)}
        sublabel="TiB"
      />
      <.stat_box label="Pipeline" value={pipeline_dots(@service_status)} sublabel="status" />
      <.stat_box
        label="Failures"
        value={format_number(@stats && @stats.failed)}
        sublabel="unresolved"
      />
      <.stat_box
        label="Library Size"
        value={format_size_gb(@stats && @stats.total_size_gb)}
        sublabel="TiB"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sublabel, :string, required: true

  defp stat_box(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
      <div class="text-xs text-gray-400 mb-1">{@label}</div>
      <div class="text-2xl font-mono text-white">{@value}</div>
      <div class="text-xs text-gray-500">{@sublabel}</div>
    </div>
    """
  end

  # CRF Search Scatter Plot (SVG visualization)
  attr :results, :list, required: true
  attr :target_vmaf, :integer, required: true
  attr :testing_crf, :float, default: nil

  defp crf_search_chart(assigns) do
    alias ReencodarrWeb.ChartHelpers

    # Calculate VMAF y-axis range from target ± results
    scores = Enum.map(assigns.results, & &1.score)

    vmaf_min =
      min(assigns.target_vmaf - 3, Enum.min(scores, fn -> assigns.target_vmaf - 3 end) - 1)

    vmaf_max =
      max(assigns.target_vmaf + 3, Enum.max(scores, fn -> assigns.target_vmaf + 3 end) + 1)

    # Dynamic CRF axis range from actual results
    {crf_min, crf_max} = ChartHelpers.crf_range_from_results(assigns.results)

    # Pre-compute dot positions
    dots =
      Enum.with_index(assigns.results, fn r, idx ->
        %{
          x: ChartHelpers.crf_to_x(r.crf, crf_min, crf_max),
          y: ChartHelpers.vmaf_to_y(r.score, vmaf_min, vmaf_max),
          crf: r.crf,
          score: r.score,
          above: r.score >= assigns.target_vmaf,
          is_latest: idx == length(assigns.results) - 1
        }
      end)

    # Calculate target line y-coordinate
    target_y = ChartHelpers.vmaf_to_y(assigns.target_vmaf, vmaf_min, vmaf_max)

    # Y-axis tick labels (every 1 VMAF)
    y_ticks =
      for vmaf <- trunc(vmaf_min)..trunc(vmaf_max) do
        %{value: vmaf, y: ChartHelpers.vmaf_to_y(vmaf, vmaf_min, vmaf_max)}
      end

    # X-axis tick labels (dynamic based on actual CRF range)
    x_ticks =
      for crf <- ChartHelpers.generate_x_ticks(trunc(crf_min), trunc(crf_max)) do
        %{value: crf, x: ChartHelpers.crf_to_x(crf, crf_min, crf_max)}
      end

    assigns =
      assign(assigns,
        vmaf_min: vmaf_min,
        vmaf_max: vmaf_max,
        crf_min: crf_min,
        crf_max: crf_max,
        dots: dots,
        target_y: target_y,
        y_ticks: y_ticks,
        x_ticks: x_ticks
      )

    ~H"""
    <svg viewBox="0 0 320 140" class="w-full" style="max-height: 200px;">
      <!-- Subtle grid lines at each VMAF integer -->
      <%= for tick <- @y_ticks do %>
        <line
          x1="30"
          y1={tick.y}
          x2="310"
          y2={tick.y}
          stroke="#374151"
          stroke-width="0.5"
          opacity="0.3"
        />
      <% end %>
      
    <!-- Target VMAF line (dashed, amber) -->
      <line
        x1="30"
        y1={@target_y}
        x2="310"
        y2={@target_y}
        stroke="#f59e0b"
        stroke-width="1.5"
        stroke-dasharray="6,4"
      />
      <text x="312" y={@target_y + 3} fill="#f59e0b" font-size="9" font-family="monospace">
        {@target_vmaf}
      </text>
      
    <!-- Result dots -->
      <%= for dot <- @dots do %>
        <circle
          cx={dot.x}
          cy={dot.y}
          r="5"
          fill={if dot.above, do: "#4ade80", else: "#f87171"}
          opacity="0.9"
        />
        <%= if dot.is_latest do %>
          <text
            x={dot.x}
            y={dot.y - 8}
            fill="#9ca3af"
            font-size="9"
            font-family="monospace"
            text-anchor="middle"
          >
            {Formatters.vmaf_score(dot.score, 1)}
          </text>
        <% end %>
      <% end %>
      
    <!-- Currently-testing CRF indicator (pulsing ring at bottom) -->
      <%= if @testing_crf do %>
        <circle
          cx={ChartHelpers.crf_to_x(@testing_crf, @crf_min, @crf_max)}
          cy="115"
          r="4"
          fill="none"
          stroke="#60a5fa"
          stroke-width="1.5"
          class="animate-pulse"
        />
        <text
          x={ChartHelpers.crf_to_x(@testing_crf, @crf_min, @crf_max)}
          y="127"
          fill="#60a5fa"
          font-size="8"
          font-family="monospace"
          text-anchor="middle"
        >
          CRF {Formatters.crf(@testing_crf)}
        </text>
      <% end %>
      
    <!-- Y-axis labels (VMAF values) -->
      <%= for tick <- @y_ticks do %>
        <text x="2" y={tick.y + 3} fill="#9ca3af" font-size="9" font-family="monospace">
          {tick.value}
        </text>
      <% end %>
      
    <!-- X-axis labels (CRF ticks) -->
      <%= for tick <- @x_ticks do %>
        <text
          x={tick.x}
          y="135"
          fill="#9ca3af"
          font-size="9"
          font-family="monospace"
          text-anchor="middle"
        >
          {tick.value}
        </text>
      <% end %>
      
    <!-- Axis lines -->
      <line x1="30" y1="10" x2="30" y2="110" stroke="#4b5563" stroke-width="1" />
      <line x1="30" y1="110" x2="310" y2="110" stroke="#4b5563" stroke-width="1" />
    </svg>
    """
  end

  # SVG coordinate helpers delegated to ChartHelpers (dynamic CRF range)

  # Row 2: CRF Search Panel Component
  attr :video, :map, required: true
  attr :results, :list, required: true
  attr :sample, :map, required: true
  attr :progress, :any, required: true
  attr :queue_count, :integer, required: true
  attr :queue_items, :list, required: true
  attr :status, :atom, required: true

  defp crf_search_panel(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-700 rounded-lg p-4 h-full">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-white">CRF Search</h3>
        <span class={"px-2 py-1 text-xs rounded-full #{service_status_class(@status)}"}>
          {service_status_text(@status)}
        </span>
      </div>

      <%= if @video do %>
        <!-- Active: Show video metadata + search results -->
        <div class="space-y-3">
          <!-- Video metadata line -->
          <div class="text-sm text-gray-300">
            <div class="font-medium truncate">{@video.filename}</div>
            <div class="text-xs text-gray-400 flex gap-2 flex-wrap">
              <span>{Formatters.file_size(@video.video_size)}</span>
              <span>{@video.width}x{@video.height}</span>
              <%= if @video.hdr do %>
                <span class="text-amber-400">HDR</span>
              <% end %>
              <span>Target: {@video.target_vmaf} VMAF</span>
            </div>
          </div>
          
    <!-- Sample progress if active -->
          <%= if @sample do %>
            <div class="text-xs text-gray-400">
              Sample {@sample.sample_num}/{@sample.total_samples} — CRF {@sample.crf}
            </div>
          <% end %>
          
    <!-- SVG scatter plot showing convergence -->
          <%= if length(@results) > 0 do %>
            <div class="space-y-2">
              <.crf_search_chart
                results={@results}
                target_vmaf={@video.target_vmaf}
                testing_crf={@sample && @sample.crf}
              />
              
    <!-- Compact results list (exact numbers) -->
              <div class="text-xs font-mono text-gray-400 space-y-0.5 max-h-24 overflow-y-auto">
                <%= for result <- @results do %>
                  <div class={[
                    "flex justify-between px-1",
                    @sample && result.crf == @sample.crf && "bg-blue-900/30 text-blue-200"
                  ]}>
                    <span>
                      CRF {Formatters.crf(result.crf)} → {Formatters.vmaf_score(result.score, 1)} VMAF
                    </span>
                    <span>{if result[:percent], do: "#{result.percent}%", else: "—"}</span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% else %>
        <!-- Idle: Show compact status -->
        <div class="text-sm text-gray-400">
          <span>Queue: {@queue_count}</span>
          <%= if @status == :idle do %>
            <span class="ml-2">• Idle</span>
          <% end %>
        </div>
      <% end %>
      
    <!-- Always show next-up videos -->
      <%= if length(@queue_items) > 0 do %>
        <div class="text-xs text-gray-500 space-y-0.5 mt-2 pt-2 border-t border-gray-800">
          <div class="text-gray-600 mb-0.5">Next up ({@queue_count}):</div>
          <%= for video <- Enum.take(@queue_items, 5) do %>
            <div class="truncate">{Path.basename(video.path)}</div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Row 2: Encoding Panel Component
  attr :video, :map, required: true
  attr :vmaf, :map, required: true
  attr :progress, :any, required: true
  attr :queue_count, :integer, required: true
  attr :queue_items, :list, required: true
  attr :status, :atom, required: true

  defp encoding_panel(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-700 rounded-lg p-4 h-full">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-white">Encoding</h3>
        <span class={"px-2 py-1 text-xs rounded-full #{service_status_class(@status)}"}>
          {service_status_text(@status)}
        </span>
      </div>

      <%= if @video do %>
        <!-- Active: Show video metadata + savings -->
        <div class="space-y-3">
          <!-- Video metadata -->
          <div class="text-sm text-gray-300">
            <div class="font-medium truncate">{@video.filename}</div>
            <div class="text-xs text-gray-400 flex gap-2 flex-wrap">
              <span>{Formatters.file_size(@video.video_size)}</span>
              <span>{@video.width}x{@video.height}</span>
              <%= if @video.hdr do %>
                <span class="text-amber-400">HDR</span>
              <% end %>
            </div>
          </div>
          
    <!-- VMAF info + savings -->
          <%= if @vmaf do %>
            <div class="space-y-1">
              <div class="text-xs text-gray-400">
                CRF {@vmaf.crf} • VMAF {Formatters.vmaf_score(@vmaf.vmaf_score, 1)}
              </div>
              <%= if @vmaf.predicted_savings do %>
                <div class="text-lg font-semibold text-green-400">
                  Saving: {Formatters.file_size(@vmaf.predicted_savings)}
                </div>
              <% end %>
            </div>
          <% end %>
          
    <!-- Progress bar -->
          <%= if @progress != :none && Map.get(@progress, :percent) != nil do %>
            <div>
              <div class="w-full bg-gray-800 rounded-full h-2 mb-1">
                <div
                  class="bg-gradient-to-r from-amber-400 to-amber-500 h-2 rounded-full transition-all"
                  style={"width: #{@progress.percent}%"}
                >
                </div>
              </div>
              <div class="flex justify-between text-xs text-gray-400">
                <span>{@progress.percent}%</span>
                <%= if @progress[:fps] do %>
                  <span>{@progress.fps} fps</span>
                <% end %>
                <%= if @progress[:eta] do %>
                  <span>ETA: {@progress.eta} {@progress[:time_unit]}</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% else %>
        <!-- Idle: Show compact status -->
        <div class="text-sm text-gray-400">
          <span>Queue: {@queue_count}</span>
          <%= if @status == :idle do %>
            <span class="ml-2">• Idle</span>
          <% end %>
        </div>
      <% end %>
      
    <!-- Always show next-up videos -->
      <%= if length(@queue_items) > 0 do %>
        <div class="text-xs text-gray-500 space-y-0.5 mt-2 pt-2 border-t border-gray-800">
          <div class="text-gray-600 mb-0.5">Next up ({@queue_count}):</div>
          <%= for vmaf <- Enum.take(@queue_items, 5) do %>
            <div class="truncate">{Path.basename(vmaf.video.path)}</div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Row 3: Pipeline Overview Component
  attr :stats, :map, required: true
  attr :service_status, :map, required: true
  attr :queue_counts, :map, required: true
  attr :analyzer_throughput, :any, required: true

  defp pipeline_overview(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
      <h3 class="font-semibold text-white mb-3">Processing Pipeline</h3>
      
    <!-- State distribution bar -->
      <%= if @stats do %>
        <.state_distribution_bar stats={@stats} />
      <% end %>
      
    <!-- Compact pipeline rows -->
      <div class="space-y-2 mt-4">
        <.pipeline_row
          name="Analysis"
          status={@service_status.analyzer}
          queue={@queue_counts.analyzer}
          metric={
            if(@analyzer_throughput && @analyzer_throughput > 0,
              do: "#{Formatters.rate(@analyzer_throughput)} files/s",
              else: nil
            )
          }
        />
        <.pipeline_row
          name="CRF Search"
          status={@service_status.crf_searcher}
          queue={@queue_counts.crf_searcher}
        />
        <.pipeline_row
          name="Encoding"
          status={@service_status.encoder}
          queue={@queue_counts.encoder}
        />
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true

  defp state_distribution_bar(assigns) do
    total = assigns.stats.total_videos || 1

    assigns =
      assign(assigns,
        needs_analysis_pct: percent(assigns.stats.needs_analysis, total),
        analyzed_pct: percent(assigns.stats.analyzed, total),
        crf_pct: percent(assigns.stats.crf_searching + assigns.stats.crf_searched, total),
        encoded_pct: percent(assigns.stats.encoded, total),
        failed_pct: percent(assigns.stats.failed, total)
      )

    ~H"""
    <div class="space-y-1">
      <div class="flex h-4 rounded overflow-hidden">
        <%= if @needs_analysis_pct > 0 do %>
          <div
            class="bg-gray-600"
            style={"width: #{@needs_analysis_pct}%"}
            title={"Needs Analysis: #{@stats.needs_analysis}"}
          >
          </div>
        <% end %>
        <%= if @analyzed_pct > 0 do %>
          <div
            class="bg-blue-500"
            style={"width: #{@analyzed_pct}%"}
            title={"Analyzed: #{@stats.analyzed}"}
          >
          </div>
        <% end %>
        <%= if @crf_pct > 0 do %>
          <div
            class="bg-amber-500"
            style={"width: #{@crf_pct}%"}
            title={"CRF Search: #{@stats.crf_searching + @stats.crf_searched}"}
          >
          </div>
        <% end %>
        <%= if @encoded_pct > 0 do %>
          <div
            class="bg-green-500"
            style={"width: #{@encoded_pct}%"}
            title={"Encoded: #{@stats.encoded}"}
          >
          </div>
        <% end %>
        <%= if @failed_pct > 0 do %>
          <div class="bg-red-500" style={"width: #{@failed_pct}%"} title={"Failed: #{@stats.failed}"}>
          </div>
        <% end %>
      </div>
      <div class="flex justify-between text-xs text-gray-400">
        <span>Needs Analysis: {format_number(@stats.needs_analysis)}</span>
        <span>Analyzed: {format_number(@stats.analyzed)}</span>
        <span>Encoded: {format_number(@stats.encoded)}</span>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :status, :atom, required: true
  attr :queue, :integer, required: true
  attr :metric, :string, default: nil

  defp pipeline_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 px-3 bg-gray-800/50 rounded">
      <div class="flex items-center gap-3">
        <span class="text-sm text-gray-300">{@name}</span>
        <span class={"px-2 py-0.5 text-xs rounded-full #{service_status_class(@status)}"}>
          {service_status_text(@status)}
        </span>
      </div>
      <div class="flex items-center gap-4 text-sm">
        <%= if @metric do %>
          <span class="text-gray-400">{@metric}</span>
        <% end %>
        <span class="text-gray-300 font-mono">Queue: {@queue}</span>
      </div>
    </div>
    """
  end

  # Row 4: Sync Controls Component
  attr :syncing, :boolean, required: true
  attr :sync_progress, :integer, required: true
  attr :service_type, :atom, required: true

  defp sync_controls(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
      <div class="flex items-center justify-between">
        <h3 class="font-semibold text-white">Media Library Sync</h3>

        <div class="flex gap-2">
          <button
            phx-click="sync_sonarr"
            disabled={@syncing}
            class={
              "px-4 py-2 text-sm rounded #{if @syncing, do: "bg-gray-700 text-gray-500 cursor-not-allowed", else: "bg-blue-600 hover:bg-blue-700 text-white"}"
            }
          >
            Sync Sonarr
          </button>
          <button
            phx-click="sync_radarr"
            disabled={@syncing}
            class={
              "px-4 py-2 text-sm rounded #{if @syncing, do: "bg-gray-700 text-gray-500 cursor-not-allowed", else: "bg-blue-600 hover:bg-blue-700 text-white"}"
            }
          >
            Sync Radarr
          </button>
        </div>
      </div>

      <%= if @syncing do %>
        <div class="mt-3">
          <div class="w-full bg-gray-800 rounded-full h-2">
            <div
              class="bg-blue-500 h-2 rounded-full transition-all"
              style={"width: #{@sync_progress}%"}
            >
            </div>
          </div>
          <div class="text-xs text-gray-400 mt-1">
            Syncing {@service_type}... {@sync_progress}%
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions for formatting
  defp format_number(nil), do: "—"

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(_), do: "—"

  defp format_completed(nil), do: "—"

  defp format_completed(stats) do
    total = stats.total_videos || 0
    encoded = stats.encoded || 0

    if total > 0 do
      pct = round(encoded / total * 100)
      "#{format_number(encoded)} (#{pct}%)"
    else
      "0 (0%)"
    end
  end

  defp format_savings(nil), do: "—"

  defp format_savings(gb) when is_number(gb) do
    # Convert GB to TiB
    tib = gb / 1024.0
    "#{:erlang.float_to_binary(tib, decimals: 2)}"
  end

  defp format_savings(_), do: "—"

  defp format_size_gb(nil), do: "—"

  defp format_size_gb(gb) when is_number(gb) do
    # Convert GB to TiB
    tib = gb / 1024.0
    "#{:erlang.float_to_binary(tib, decimals: 1)}"
  end

  defp format_size_gb(_), do: "—"

  defp pipeline_dots(service_status) do
    analyzer = dot_for_status(service_status.analyzer)
    crf = dot_for_status(service_status.crf_searcher)
    encoder = dot_for_status(service_status.encoder)
    raw("#{analyzer} #{crf} #{encoder}")
  end

  defp dot_for_status(status) when status in [:running, :processing],
    do: "<span class='inline-block w-2 h-2 rounded-full bg-green-500'></span>"

  defp dot_for_status(:stopped),
    do: "<span class='inline-block w-2 h-2 rounded-full bg-red-500'></span>"

  defp dot_for_status(_),
    do: "<span class='inline-block w-2 h-2 rounded-full bg-gray-500'></span>"

  defp percent(_count, 0), do: 0
  defp percent(count, total), do: round(count / total * 100)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 p-6">
      <div class="max-w-7xl mx-auto space-y-4">
        <!-- Row 1: Stats Bar -->
        <.stats_bar stats={@stats} service_status={@service_status} />
        
    <!-- Row 2: Active Work Panels -->
        <div class="grid grid-cols-1 lg:grid-cols-5 gap-4">
          <div class="lg:col-span-3">
            <.crf_search_panel
              video={@crf_search_video}
              results={@crf_search_results}
              sample={@crf_search_sample}
              progress={@crf_progress}
              queue_count={@queue_counts.crf_searcher}
              queue_items={@queue_items.crf_searcher}
              status={@service_status.crf_searcher}
            />
          </div>
          <div class="lg:col-span-2">
            <.encoding_panel
              video={@encoding_video}
              vmaf={@encoding_vmaf}
              progress={@encoding_progress}
              queue_count={@queue_counts.encoder}
              queue_items={@queue_items.encoder}
              status={@service_status.encoder}
            />
          </div>
        </div>
        
    <!-- Row 3: Pipeline Overview -->
        <.pipeline_overview
          stats={@stats}
          service_status={@service_status}
          queue_counts={@queue_counts}
          analyzer_throughput={@analyzer_throughput}
        />
        
    <!-- Row 4: Sync Controls -->
        <.sync_controls
          syncing={@syncing}
          sync_progress={@sync_progress}
          service_type={@service_type}
        />
      </div>
    </div>
    """
  end

  # Helper functions for real data
  # Simple service status - just check if processes are alive
  defp get_optimistic_service_status do
    %{
      analyzer: if(Process.whereis(@producer_modules.analyzer), do: :idle, else: :stopped),
      crf_searcher: if(CrfSearcherBroadway.running?(), do: :idle, else: :stopped),
      encoder: if(Process.whereis(@producer_modules.encoder), do: :idle, else: :stopped)
    }
  end

  defp request_current_status do
    # Send cast to each producer to broadcast their current status
    Enum.each(@producer_modules, fn {_service, producer_module} ->
      case Process.whereis(producer_module) do
        nil ->
          # Process doesn't exist - no broadcast needed (LiveView handles via progress events)
          :ok

        _pid ->
          GenServer.cast(producer_module, :broadcast_status)
      end
    end)
  end

  # DRY status mappings using maps instead of multiple function clauses
  @service_status_styles %{
    running: "bg-green-100 text-green-800",
    paused: "bg-yellow-100 text-yellow-800",
    processing: "bg-blue-100 text-blue-800",
    pausing: "bg-orange-100 text-orange-800",
    idle: "bg-cyan-100 text-cyan-800",
    checking: "bg-gray-100 text-gray-600 animate-pulse",
    stopped: "bg-red-100 text-red-800",
    unknown: "bg-gray-100 text-gray-800"
  }

  @service_status_labels %{
    running: "Running",
    paused: "Paused",
    processing: "Processing",
    pausing: "Pausing",
    idle: "Idle",
    checking: "Checking...",
    stopped: "Stopped",
    unknown: "Unknown"
  }

  defp service_status_class(status),
    do: @service_status_styles[status] || @service_status_styles.unknown

  defp service_status_text(status),
    do: @service_status_labels[status] || @service_status_labels.unknown

  defp request_analyzer_throughput do
    do_request_analyzer_throughput(
      GenServer.whereis(Reencodarr.Analyzer.Broadway.PerformanceMonitor)
    )
  end

  defp do_request_analyzer_throughput(nil), do: :ok
  defp do_request_analyzer_throughput(pid), do: GenServer.cast(pid, {:throughput_request, self()})

  defp schedule_periodic_update do
    Process.send_after(self(), :update_dashboard_data, 5_000)
  end

  # Helper functions to reduce duplication
  defp calculate_progress_percent(data) do
    if data[:current] && data[:total] && data.total > 0 do
      round(data.current / data.total * 100)
    else
      data[:percent] || 0
    end
  end
end
