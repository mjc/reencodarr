defmodule ReencodarrWeb.DashboardLive do
  @moduledoc """
  Dashboard with simplified 3-layer architecture.

  Service Layer -> PubSub -> LiveView

  This eliminates the complex telemetry chain and provides immediate updates.
  """
  use ReencodarrWeb, :live_view

  alias Reencodarr.CrfSearcher.Broadway, as: CrfSearcherBroadway
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Formatters
  alias Reencodarr.Media.{Video, VideoQueries, Vmaf}
  alias Reencodarr.Repo

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
        crf_progress: :none,
        encoding_progress: :none,
        analyzer_progress: :none,
        analyzer_throughput: nil,
        # Start with empty placeholders and fetch async to avoid blocking LiveView
        queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
        queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
        service_status: get_optimistic_service_status(),
        syncing: false,
        sync_progress: 0,
        service_type: nil
      })

    # Setup subscriptions and processes if connected
    if connected?(socket) do
      # Subscribe to the single clean dashboard channel
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      # Subscribe to pipeline state changes
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
      # Request current status from all services with a small delay to let services initialize
      Process.send_after(self(), :request_status, 100)
      # Start periodic updates for queue counts and service status
      schedule_periodic_update()
      # Fetch the initial queue counts/items asynchronously so mount returns quickly
      request_dashboard_queue_async()
      # Request throughput async
      request_analyzer_throughput()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # All handle_info callbacks grouped together
  @impl true
  def handle_info({:analyzer_started, _data}, socket) do
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :analyzer, :running)
    {:noreply, assign(socket, :service_status, updated_status)}
  end

  # Pipeline state change events - use actual states from PipelineStateMachine
  @impl true
  def handle_info({:analyzer, state}, socket) when is_atom(state) do
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :analyzer, state)
    {:noreply, assign(socket, :service_status, updated_status)}
  end

  @impl true
  def handle_info({:crf_searcher, state}, socket) when is_atom(state) do
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :crf_searcher, state)
    {:noreply, assign(socket, :service_status, updated_status)}
  end

  @impl true
  def handle_info({:encoder, state}, socket) when is_atom(state) do
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :encoder, state)
    {:noreply, assign(socket, :service_status, updated_status)}
  end

  @impl true
  def handle_info({:crf_search_started, _data}, socket) do
    # Don't create incomplete progress data - wait for actual progress events
    {:noreply, socket}
  end

  @impl true
  def handle_info({:crf_search_progress, data}, socket) do
    progress = %{
      percent: calculate_progress_percent(data),
      filename: data[:filename],
      crf: data[:crf],
      score: data[:score]
    }

    # Update status to processing since we're receiving active progress
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :crf_searcher, :processing)

    socket
    |> assign(:crf_progress, progress)
    |> assign(:service_status, updated_status)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_info({:encoding_started, data}, socket) do
    progress = %{
      percent: 0,
      video_id: data.video_id,
      filename: data.filename
    }

    # Update status to processing since encoding is actually running
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :encoder, :processing)

    socket
    |> assign(:encoding_progress, progress)
    |> assign(:service_status, updated_status)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_info({:encoding_progress, data}, socket) do
    progress = %{
      percent: calculate_progress_percent(data),
      filename: data[:filename],
      fps: data[:fps],
      eta: data[:eta],
      time_unit: data[:time_unit],
      timestamp: data[:timestamp],
      video_id: data[:video_id]
    }

    # Update status to processing since we're receiving active progress
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :encoder, :processing)

    socket
    |> assign(:encoding_progress, progress)
    |> assign(:service_status, updated_status)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_info({:analyzer_progress, data}, socket) do
    progress = %{
      percent: calculate_progress_percent(data),
      count: data[:current] || data[:count],
      total: data[:total],
      batch_size: data[:batch_size]
    }

    # Update status to processing since we're receiving active progress
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :analyzer, :processing)

    socket
    |> assign(:analyzer_progress, progress)
    |> assign(:service_status, updated_status)
    |> then(&{:noreply, &1})
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

  # Completion and reset handlers
  @impl true
  def handle_info({:encoding_completed, _data}, socket) do
    # Reset status back to idle when encoding completes
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :encoder, :idle)

    socket
    |> assign(:encoding_progress, :none)
    |> assign(:service_status, updated_status)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_info({event, _data}, socket) when event in [:crf_search_completed] do
    # Reset status back to idle when CRF search completes
    current_status = socket.assigns.service_status
    updated_status = Map.put(current_status, :crf_searcher, :idle)

    socket
    |> assign(:crf_progress, :none)
    |> assign(:service_status, updated_status)
    |> then(&{:noreply, &1})
  end

  # Special CRF search event handlers
  @impl true
  def handle_info({:crf_search_encoding_sample, data}, socket) do
    progress = %{filename: data.filename, crf: data.crf, percent: 0}
    {:noreply, assign(socket, :crf_progress, progress)}
  end

  @impl true
  def handle_info({:crf_search_vmaf_result, data}, socket) do
    progress = %{filename: data.filename, crf: data.crf, score: data.score, percent: 100}
    {:noreply, assign(socket, :crf_progress, progress)}
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

    # Fetch queue data asynchronously to avoid DB checkout blocking the LiveView process
    request_dashboard_queue_async()

    {:noreply, socket}
  end

  @impl true
  # Receive asynchronous dashboard queue data and assign it
  def handle_info({:dashboard_queue_update, queue_counts, queue_items}, socket) do
    {:noreply, assign(socket, queue_counts: queue_counts, queue_items: queue_items)}
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

  # Service control event handlers - pipelines always run, no start/pause
  @impl true
  def handle_event("start_analyzer", _params, socket) do
    {:noreply, put_flash(socket, :info, "Analyzer runs automatically")}
  end

  @impl true
  def handle_event("pause_analyzer", _params, socket) do
    {:noreply, put_flash(socket, :info, "Analyzer runs automatically")}
  end

  @impl true
  def handle_event("start_crf_searcher", _params, socket) do
    {:noreply, put_flash(socket, :info, "CRF Search runs automatically")}
  end

  @impl true
  def handle_event("pause_crf_searcher", _params, socket) do
    {:noreply, put_flash(socket, :info, "CRF Search runs automatically")}
  end

  @impl true
  def handle_event("start_encoder", _params, socket) do
    {:noreply, put_flash(socket, :info, "Encoder runs automatically")}
  end

  @impl true
  def handle_event("pause_encoder", _params, socket) do
    {:noreply, put_flash(socket, :info, "Encoder runs automatically")}
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

  # Unified pipeline step component
  defp pipeline_step(assigns) do
    ~H"""
    <div class="text-center bg-white/5 backdrop-blur-sm rounded-lg p-4 border border-white/10">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-white">{@name}</h3>
        <span class={"px-2 py-1 text-xs rounded-full #{service_status_class(@status)}"}>
          {service_status_text(@status)}
        </span>
      </div>

      <div class="mb-3">
        <div class="text-2xl font-mono text-purple-100 mb-1">
          {@queue}
        </div>
        <div class="text-xs text-purple-300">queued</div>
      </div>

      <%= if @progress != :none do %>
        <div class="mb-3">
          <div class="w-full bg-purple-900/50 rounded-full h-2 mb-2 border border-purple-500/30">
            <div
              class={"bg-gradient-to-r from-#{@color}-400 to-#{@color}-500 h-2 rounded-full transition-all duration-300 shadow-lg shadow-#{@color}-500/50"}
              style={"width: #{Map.get(@progress, :percent, 0)}%"}
            >
            </div>
          </div>
          <div class="text-sm text-purple-100">
            {Map.get(@progress, :percent, 0)}%
          </div>
        </div>
        <%= if Map.get(@progress, :filename) do %>
          <div class="text-xs text-purple-200 truncate mb-2">
            {Path.basename(Map.get(@progress, :filename, ""))}
          </div>
        <% end %>
        {render_slot(@inner_block)}
      <% else %>
        <div class="text-xs text-purple-400 mb-3">Idle</div>
      <% end %>
      
    <!-- Queue Items Display -->
      <%= if length(@queue_items) > 0 do %>
        <div class="mb-3">
          <h4 class="text-xs font-semibold text-purple-200 mb-2">Next in Queue</h4>
          <div class="space-y-1">
            <%= for item <- Enum.take(@queue_items, 3) do %>
              <div class="bg-purple-900/30 rounded p-2 text-left border border-purple-500/20">
                <div class="text-xs font-medium text-purple-100 truncate">
                  {Path.basename(get_item_path(item))}
                </div>
                <div class="text-xs text-purple-300 flex justify-between">
                  <span>{Formatters.file_size(get_item_size(item))}</span>
                  <span>{Formatters.bitrate(get_item_bitrate(item))}</span>
                </div>
                <%= if Map.has_key?(item, :crf) do %>
                  <div class="text-xs text-purple-400">
                    CRF: {item.crf}
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <div class="flex gap-2">
        <button
          phx-click={"start_#{@service}"}
          class="flex-1 bg-green-600 hover:bg-green-500 text-white text-xs py-1 px-2 rounded shadow-lg"
        >
          Start
        </button>
        <button
          phx-click={"pause_#{@service}"}
          class="flex-1 bg-amber-600 hover:bg-amber-500 text-white text-xs py-1 px-2 rounded shadow-lg"
        >
          Pause
        </button>
      </div>
    </div>
    """
  end

  # Simplified sync service component
  defp sync_service(assigns) do
    assigns =
      assigns
      |> assign(:active, assigns.syncing && assigns.service_type == assigns.service)
      |> assign(:status_class, sync_status_class(assigns))
      |> assign(:status_text, sync_status_text(assigns))

    ~H"""
    <div class="text-center bg-white/5 backdrop-blur-sm rounded-lg p-4 border border-white/10">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-white">{@name}</h3>
        <span class={"px-2 py-1 text-xs rounded-full #{@status_class}"}>
          {@status_text}
        </span>
      </div>

      <%= if @active do %>
        <div class="mb-3">
          <div class="w-full bg-purple-900/50 rounded-full h-2 mb-2 border border-purple-500/30">
            <div
              class="bg-gradient-to-r from-blue-400 to-blue-500 h-2 rounded-full transition-all duration-300 shadow-lg shadow-blue-500/50"
              style={"width: #{@sync_progress}%"}
            >
            </div>
          </div>
          <div class="text-sm text-purple-100">{@sync_progress}%</div>
        </div>
      <% else %>
        <div class="text-xs text-purple-400 mb-3">
          {if @syncing, do: "Waiting for other service", else: "Ready to sync"}
        </div>
      <% end %>

      <button
        phx-click={"sync_#{@service}"}
        disabled={@syncing}
        class={"w-full text-xs py-2 px-3 rounded shadow-lg #{sync_button_class(@syncing)}"}
      >
        Sync {@name}
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-purple-900 via-violet-900 to-purple-800 p-6">
      <div class="max-w-7xl mx-auto space-y-6">
        <!-- Header -->
        <div class="flex justify-between items-start">
          <div class="flex items-center gap-4">
            <img src="/images/favicon.svg" alt="Reencodarr" class="w-16 h-16 drop-shadow-lg" />
            <div>
              <h1 class="text-4xl font-bold text-white">Reencodarr</h1>
              <p class="text-purple-200">AV1/Opus Video Transcoding Pipeline</p>
            </div>
          </div>
          <.link
            navigate={~p"/failures"}
            class="bg-red-500 hover:bg-red-600 text-white font-semibold py-2 px-4 rounded-lg shadow-lg transition-colors flex items-center gap-2"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              viewBox="0 0 20 20"
              fill="currentColor"
            >
              <path
                fill-rule="evenodd"
                d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                clip-rule="evenodd"
              />
            </svg>
            View Failures
          </.link>
        </div>
        
    <!-- Main Processing Pipeline -->
        <div class="bg-white/10 backdrop-blur-sm rounded-lg shadow-lg p-6 border border-white/20">
          <h2 class="text-xl font-semibold mb-4 text-white">Processing Pipeline</h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
            <.pipeline_step
              name="Analysis"
              service="analyzer"
              status={@service_status.analyzer}
              queue={@queue_counts.analyzer}
              queue_items={@queue_items.analyzer}
              progress={@analyzer_progress}
              color="purple"
            >
              <%= if @analyzer_throughput && @analyzer_throughput > 0 do %>
                <div class="text-xs text-purple-200">
                  Rate: {Reencodarr.Formatters.rate(@analyzer_throughput)} files/s
                </div>
              <% end %>
              <%= if @analyzer_progress != :none && Map.get(@analyzer_progress, :batch_size) do %>
                <div class="text-xs text-purple-200">
                  Batch: {Map.get(@analyzer_progress, :batch_size)} files
                </div>
              <% end %>
              <%= if @analyzer_progress != :none && Map.get(@analyzer_progress, :last_batch_size) do %>
                <div class="text-xs text-purple-300">
                  Last batch: {Map.get(@analyzer_progress, :last_batch_size)} files
                </div>
              <% end %>
            </.pipeline_step>

            <.pipeline_step
              name="CRF Search"
              service="crf_searcher"
              status={@service_status.crf_searcher}
              queue={@queue_counts.crf_searcher}
              queue_items={@queue_items.crf_searcher}
              progress={@crf_progress}
              color="blue"
            >
              <%= if Map.get(@crf_progress, :crf) do %>
                <div class="text-xs text-purple-200">
                  CRF: {Map.get(@crf_progress, :crf, 0)}
                  <%= if Map.get(@crf_progress, :score) do %>
                    | VMAF: {Map.get(@crf_progress, :score, 0)}
                  <% end %>
                </div>
              <% end %>
            </.pipeline_step>

            <.pipeline_step
              name="Encoding"
              service="encoder"
              status={@service_status.encoder}
              queue={@queue_counts.encoder}
              queue_items={@queue_items.encoder}
              progress={@encoding_progress}
              color="amber"
            >
              <%= if Map.get(@encoding_progress, :fps) do %>
                <div class="text-xs text-purple-200">
                  {Map.get(@encoding_progress, :fps, 0)} fps
                  <%= if Map.get(@encoding_progress, :eta) do %>
                    | ETA: {Map.get(@encoding_progress, :eta, 0)} {Map.get(
                      @encoding_progress,
                      :time_unit,
                      ""
                    )}
                  <% end %>
                </div>
              <% end %>
            </.pipeline_step>
          </div>
        </div>
        
    <!-- External Sync Services -->
        <div class="bg-white/10 backdrop-blur-sm rounded-lg shadow-lg p-6 border border-white/20">
          <h2 class="text-xl font-semibold mb-4 text-white">Media Library Sync</h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <.sync_service
              name="Sonarr"
              service={:sonarr}
              syncing={@syncing}
              sync_progress={@sync_progress}
              service_type={@service_type}
            />
            <.sync_service
              name="Radarr"
              service={:radarr}
              syncing={@syncing}
              sync_progress={@sync_progress}
              service_type={@service_type}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions for real data
  # Dashboard polls regularly, so use a short timeout (2s) to avoid blocking
  # If SQLite is busy, we'll skip this update and get data on next poll
  @dashboard_query_timeout 2_000

  defp get_queue_counts do
    import Ecto.Query

    %{
      analyzer:
        safe_query(fn ->
          Repo.one(
            from(v in Video, where: v.state == :needs_analysis, select: count()),
            timeout: @dashboard_query_timeout
          )
        end),
      crf_searcher: count_videos_for_crf_search_with_timeout(),
      encoder:
        safe_query(fn ->
          Repo.one(
            from(v in Vmaf,
              join: vid in assoc(v, :video),
              where: v.chosen == true and vid.state == :crf_searched,
              select: count(v.id)
            ),
            timeout: @dashboard_query_timeout
          )
        end)
    }
  end

  # Wrapper to safely execute queries and return 0 on timeout or connection errors
  defp safe_query(fun) do
    fun.()
  rescue
    DBConnection.ConnectionError -> 0
  catch
    :exit, {:timeout, _} -> 0
    # In tests, owner process may exit during async queries
    :exit, {%DBConnection.ConnectionError{}, _} -> 0
  end

  # Inline CRF search count to apply timeout - simplified without codec checks
  defp count_videos_for_crf_search_with_timeout do
    import Ecto.Query

    safe_query(fn ->
      Repo.one(
        from(v in Video,
          where: v.state == :analyzed,
          select: count()
        ),
        timeout: @dashboard_query_timeout
      )
    end)
  end

  # Get detailed queue items for each pipeline
  defp get_queue_items do
    %{
      analyzer:
        safe_query_list(fn ->
          VideoQueries.videos_needing_analysis(5, timeout: @dashboard_query_timeout)
        end),
      crf_searcher:
        safe_query_list(fn ->
          VideoQueries.videos_for_crf_search(5, timeout: @dashboard_query_timeout)
        end),
      encoder:
        safe_query_list(fn ->
          VideoQueries.videos_ready_for_encoding(5, timeout: @dashboard_query_timeout)
        end)
    }
  end

  # Wrapper for list queries - return empty list on timeout or connection errors
  defp safe_query_list(fun) do
    fun.()
  rescue
    DBConnection.ConnectionError -> []
  catch
    :exit, {:timeout, _} -> []
    # In tests, owner process may exit during async queries
    :exit, {%DBConnection.ConnectionError{}, _} -> []
  end

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

  # Fetch queue counts and items in a background task and send results back to the LiveView
  defp request_dashboard_queue_async do
    # In test mode, run synchronously to avoid DB connection issues during cleanup
    if Application.get_env(:reencodarr, :env) == :test do
      counts = get_queue_counts()
      items = get_queue_items()
      send(self(), {:dashboard_queue_update, counts, items})
    else
      parent = self()

      Task.Supervisor.start_child(ReencodarrWeb.TaskSupervisor, fn ->
        # Use short timeout for dashboard queries since it polls regularly
        # If DB is busy, safe_query/safe_query_list will return defaults (0 or [])
        counts = get_queue_counts()
        items = get_queue_items()
        send(parent, {:dashboard_queue_update, counts, items})
      end)
    end
  end

  # Helper functions to reduce duplication
  defp calculate_progress_percent(data) do
    if data[:current] && data[:total] && data.total > 0 do
      round(data.current / data.total * 100)
    else
      data[:percent] || 0
    end
  end

  # Queue item data helpers - handle both video and non-video items
  defp get_item_path(%{video: video}), do: video.path
  defp get_item_path(%{path: path}), do: path

  defp get_item_size(%{video: video}), do: video.size
  defp get_item_size(%{size: size}), do: size

  defp get_item_bitrate(%{video: video}), do: video.bitrate
  defp get_item_bitrate(%{bitrate: bitrate}), do: bitrate

  # Sync service styling helpers
  defp sync_status_class(%{syncing: true, service_type: service, service: service}),
    do: "bg-blue-100 text-blue-800 animate-pulse"

  defp sync_status_class(_assigns),
    do: "bg-gray-100 text-gray-600"

  defp sync_status_text(%{syncing: true, service_type: service, service: service}),
    do: "Syncing"

  defp sync_status_text(_assigns),
    do: "Ready"

  defp sync_button_class(true),
    do: "bg-gray-300 text-gray-500 cursor-not-allowed"

  defp sync_button_class(false),
    do: "bg-blue-500 hover:bg-blue-600 text-white"
end
