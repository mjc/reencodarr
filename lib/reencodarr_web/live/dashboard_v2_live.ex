defmodule ReencodarrWeb.DashboardV2Live do
  @moduledoc """
  New dashboard with simplified 3-layer architecture.

  Service Layer -> PubSub -> LiveView

  This eliminates the complex telemetry chain and provides immediate updates.
  """
  use ReencodarrWeb, :live_view

  alias Reencodarr.Dashboard.Events

  require Logger

  # Simple state - just what we need for UI
  defstruct crf_progress: :none,
            encoding_progress: :none,
            analyzer_progress: :none,
            analyzer_throughput: 0.0,
            connected?: false,
            queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
            service_status: %{analyzer: :unknown, crf_searcher: :unknown, encoder: :unknown},
            syncing: false,
            sync_progress: 0,
            service_type: nil

  @impl true
  def mount(_params, _session, socket) do
    initial_state = %__MODULE__{
      connected?: connected?(socket),
      queue_counts: get_queue_counts(),
      service_status: get_service_status(),
      # Will be fetched async
      analyzer_throughput: nil
    }

    # Request throughput async if connected
    if connected?(socket) do
      request_analyzer_throughput()
    end

    {:ok, assign(socket, :state, initial_state)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if socket.assigns.state.connected? do
      # Subscribe to the single clean dashboard channel
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      # Request current status from all services
      request_current_status()
      # Start periodic updates for queue counts and service status
      :timer.send_interval(5_000, self(), :update_dashboard_data)
    end

    {:noreply, socket}
  end

  # Helper function to safely get progress field values
  defp progress_field(progress, field, default \\ 0)
  defp progress_field(:none, _field, default), do: default

  defp progress_field(progress, field, default) when is_map(progress) do
    Map.get(progress, field, default)
  end

  # Handle clean dashboard events
  @impl true
  def handle_info({:crf_search_started, _data}, socket) do
    # Don't create incomplete progress data - wait for actual progress events
    {:noreply, socket}
  end

  @impl true
  def handle_info({:crf_search_progress, data}, socket) do
    state = socket.assigns.state

    # Handle different progress data formats
    percent =
      if data[:current] && data[:total] && data.total > 0 do
        round(data.current / data.total * 100)
      else
        data[:percent] || 0
      end

    updated_state = %{
      state
      | crf_progress: %{
          percent: percent,
          filename: data[:filename],
          crf: data[:crf],
          score: data[:score]
        }
    }

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:crf_search_completed, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | crf_progress: :none}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:crf_search_encoding_sample, data}, socket) do
    state = socket.assigns.state

    updated_state = %{
      state
      | crf_progress: %{
          filename: data.filename,
          crf: data.crf,
          percent: 0
        }
    }

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:crf_search_vmaf_result, data}, socket) do
    state = socket.assigns.state

    updated_state = %{
      state
      | crf_progress: %{
          filename: data.filename,
          crf: data.crf,
          score: data.score,
          percent: 100
        }
    }

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:encoding_started, data}, socket) do
    state = socket.assigns.state

    updated_state = %{
      state
      | encoding_progress: %{
          percent: 0,
          video_id: data.video_id,
          filename: data.filename
        }
    }

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:encoding_progress, data}, socket) do
    state = socket.assigns.state

    # Handle different progress data formats safely
    percent =
      if data[:current] && data[:total] && data.total > 0 do
        round(data.current / data.total * 100)
      else
        data[:percent] || 0
      end

    updated_state = %{
      state
      | encoding_progress: %{
          percent: percent,
          fps: data[:fps],
          eta: data[:eta],
          time_unit: data[:time_unit],
          timestamp: data[:timestamp],
          video_id: data[:video_id]
        }
    }

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:analyzer_progress, data}, socket) do
    state = socket.assigns.state

    # Calculate percent if we have current/total, otherwise use existing percent
    percent =
      if data[:current] && data[:total] && data.total > 0 do
        round(data.current / data.total * 100)
      else
        data[:percent] || 0
      end

    updated_state = %{
      state
      | analyzer_progress: %{
          percent: percent,
          count: data[:current] || data[:count],
          total: data[:total]
        }
    }

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:analyzer_throughput, data}, socket) do
    state = socket.assigns.state

    updated_state = %{state | analyzer_throughput: data.throughput || 0.0}

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:analyzer_started, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | analyzer: :running}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:analyzer_stopped, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | analyzer: :paused}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:analyzer_idle, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | analyzer: :idle}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:analyzer_pausing, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | analyzer: :pausing}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:crf_searcher_started, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | crf_searcher: :running}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:crf_searcher_stopped, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | crf_searcher: :paused}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:crf_searcher_idle, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | crf_searcher: :idle}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:crf_searcher_pausing, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | crf_searcher: :pausing}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:encoder_started, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | encoder: :running}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:encoder_stopped, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | encoder: :paused}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:encoder_idle, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | encoder: :idle}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:encoder_pausing, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | service_status: %{state.service_status | encoder: :pausing}}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info(:update_dashboard_data, socket) do
    state = socket.assigns.state

    updated_state = %{
      state
      | queue_counts: get_queue_counts()
    }

    # Request updated throughput async (don't block)
    request_analyzer_throughput()

    {:noreply, assign(socket, :state, updated_state)}
  end

  # Sync event handlers
  @impl true
  def handle_info({:sync_started, data}, socket) do
    state = socket.assigns.state
    service_type = Map.get(data, :service_type)
    updated_state = %{state | syncing: true, sync_progress: 0, service_type: service_type}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:sync_progress, data}, socket) do
    state = socket.assigns.state
    progress = Map.get(data, :progress, 0)
    updated_state = %{state | sync_progress: progress}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:sync_completed, _data}, socket) do
    state = socket.assigns.state
    updated_state = %{state | syncing: false, sync_progress: 0, service_type: nil}
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:sync_failed, data}, socket) do
    state = socket.assigns.state
    error = Map.get(data, :error, "Unknown error")
    updated_state = %{state | syncing: false, sync_progress: 0, service_type: nil}
    socket = put_flash(socket, :error, "Sync failed: #{inspect(error)}")
    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info(message, socket) do
    Logger.debug("DashboardV2: Unhandled message: #{inspect(message)}")
    {:noreply, socket}
  end

  # Real event handlers for actual system control
  @impl true
  def handle_event("start_analyzer", _params, socket) do
    Reencodarr.Analyzer.Broadway.Producer.start()
    {:noreply, put_flash(socket, :info, "Analyzer started")}
  end

  def handle_event("start_crf_searcher", _params, socket) do
    Reencodarr.CrfSearcher.Broadway.Producer.start()
    {:noreply, put_flash(socket, :info, "CRF Searcher started")}
  end

  def handle_event("start_encoder", _params, socket) do
    Reencodarr.Encoder.Broadway.Producer.start()
    {:noreply, put_flash(socket, :info, "Encoder started")}
  end

  @impl true
  def handle_event("pause_analyzer", _params, socket) do
    Reencodarr.Analyzer.Broadway.Producer.pause()
    {:noreply, put_flash(socket, :info, "Analyzer paused")}
  end

  def handle_event("pause_crf_searcher", _params, socket) do
    Reencodarr.CrfSearcher.Broadway.Producer.pause()
    {:noreply, put_flash(socket, :info, "CRF Searcher paused")}
  end

  def handle_event("pause_encoder", _params, socket) do
    Reencodarr.Encoder.Broadway.Producer.pause()
    {:noreply, put_flash(socket, :info, "Encoder paused")}
  end

  @impl true
  def handle_event("sync_" <> service, _params, socket) do
    sync_service(service, socket)
  end

  # Reusable progress card component for DRY HTML consolidation
  defp progress_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow-lg p-6">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold text-gray-900">{@title}</h2>
        <div class={"w-3 h-3 rounded-full #{if @progress != :none, do: "bg-green-400 animate-pulse", else: "bg-gray-300"}"}>
        </div>
      </div>

      <%= if @progress != :none do %>
        <div class="space-y-3">
          {render_slot(@inner_block)}
        </div>
      <% else %>
        <div class="text-center py-8">
          <div class="text-gray-400 text-sm">{@inactive_message}</div>
          <%= if assigns[:extra_info] do %>
            {render_slot(@extra_info)}
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 p-6">
      <div class="max-w-7xl mx-auto">
        <div class="mb-8">
          <h1 class="text-3xl font-bold text-gray-900">Dashboard V2</h1>
          <p class="mt-2 text-sm text-gray-600">Direct architecture - Service → PubSub → LiveView</p>
        </div>
        
    <!-- Processing Services Status and Controls -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-6">
          <.service_card
            name="Analyzer"
            service="analyzer"
            status={@state.service_status.analyzer}
            queue={@state.queue_counts.analyzer}
          />
          <.service_card
            name="CRF Searcher"
            service="crf_searcher"
            status={@state.service_status.crf_searcher}
            queue={@state.queue_counts.crf_searcher}
          />
          <.service_card
            name="Encoder"
            service="encoder"
            status={@state.service_status.encoder}
            queue={@state.queue_counts.encoder}
          />
        </div>
        
    <!-- Sync Services Status and Controls -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
          <.sync_card
            name="Sonarr"
            service={:sonarr}
            syncing={@state.syncing}
            service_type={@state.service_type}
            progress={@state.sync_progress}
          />
          <.sync_card
            name="Radarr"
            service={:radarr}
            syncing={@state.syncing}
            service_type={@state.service_type}
            progress={@state.sync_progress}
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <.progress_card
            title="Analysis"
            progress={@state.analyzer_progress}
            inactive_message="No active analysis"
          >
            <div class="flex justify-between items-center">
              <span class="text-sm font-medium text-gray-700">Progress</span>
              <span class="text-sm font-mono text-gray-900">
                {progress_field(@state.analyzer_progress, :percent, 0)}%
              </span>
            </div>

            <div class="w-full bg-gray-200 rounded-full h-2">
              <div
                class="bg-purple-500 h-2 rounded-full transition-all duration-300 ease-out"
                style={"width: #{progress_field(@state.analyzer_progress, :percent, 0)}%"}
              >
              </div>
            </div>

            <%= if progress_field(@state.analyzer_progress, :count) && progress_field(@state.analyzer_progress, :total) do %>
              <div class="flex justify-between text-xs text-gray-600">
                <span>
                  Files: {progress_field(@state.analyzer_progress, :count)}/{progress_field(
                    @state.analyzer_progress,
                    :total
                  )}
                </span>
                <%= if @state.analyzer_throughput && @state.analyzer_throughput > 0 do %>
                  <span>Rate: {Float.round(@state.analyzer_throughput, 1)} files/s</span>
                <% end %>
              </div>
            <% end %>

            <:extra_info>
              <%= if @state.analyzer_throughput && @state.analyzer_throughput > 0 do %>
                <div class="text-xs text-gray-500 mt-1">
                  Last rate: {Float.round(@state.analyzer_throughput, 1)} files/s
                </div>
              <% end %>
            </:extra_info>
          </.progress_card>

          <.progress_card
            title="CRF Search"
            progress={@state.crf_progress}
            inactive_message="No CRF search"
          >
            <div class="flex justify-between items-center">
              <span class="text-sm font-medium text-gray-700">Progress</span>
              <span class="text-sm font-mono text-gray-900">
                {progress_field(@state.crf_progress, :percent, 0)}%
              </span>
            </div>

            <div class="w-full bg-gray-200 rounded-full h-2">
              <div
                class="bg-blue-500 h-2 rounded-full transition-all duration-300 ease-out"
                style={"width: #{progress_field(@state.crf_progress, :percent, 0)}%"}
              >
              </div>
            </div>

            <%= if progress_field(@state.crf_progress, :filename, nil) do %>
              <div class="text-xs text-gray-500 truncate">
                {Path.basename(progress_field(@state.crf_progress, :filename, nil))}
              </div>
            <% end %>

            <%= if progress_field(@state.crf_progress, :crf) do %>
              <div class="flex justify-between text-xs">
                <span class="text-gray-600">CRF: {progress_field(@state.crf_progress, :crf)}</span>
                <%= if progress_field(@state.crf_progress, :score) do %>
                  <span class="text-gray-600">
                    VMAF: {progress_field(@state.crf_progress, :score)}
                  </span>
                <% end %>
              </div>
            <% end %>
          </.progress_card>

          <.progress_card
            title="Encoding"
            progress={@state.encoding_progress}
            inactive_message="No encoding"
          >
            <div class="flex justify-between items-center">
              <span class="text-sm font-medium text-gray-700">Progress</span>
              <span class="text-sm font-mono text-gray-900">
                {progress_field(@state.encoding_progress, :percent, 0)}%
              </span>
            </div>

            <div class="w-full bg-gray-200 rounded-full h-2">
              <div
                class="bg-green-500 h-2 rounded-full transition-all duration-300 ease-out"
                style={"width: #{progress_field(@state.encoding_progress, :percent, 0)}%"}
              >
              </div>
            </div>

            <%= if progress_field(@state.encoding_progress, :filename, nil) do %>
              <div class="text-xs text-gray-500 truncate">
                {Path.basename(progress_field(@state.encoding_progress, :filename, nil))}
              </div>
            <% end %>

            <%= if progress_field(@state.encoding_progress, :fps) do %>
              <div class="flex justify-between text-xs text-gray-600">
                <span>Speed: {progress_field(@state.encoding_progress, :fps)} fps</span>
                <%= if progress_field(@state.encoding_progress, :eta) && progress_field(@state.encoding_progress, :time_unit) do %>
                  <span>
                    ETA: {progress_field(@state.encoding_progress, :eta)} {progress_field(
                      @state.encoding_progress,
                      :time_unit
                    )}
                  </span>
                <% end %>
              </div>
            <% end %>
          </.progress_card>
        </div>
        
    <!-- Architecture Info -->
        <div class="mt-8 bg-blue-50 border border-blue-200 rounded-lg p-6">
          <h3 class="text-lg font-semibold text-blue-800 mb-2">Architecture</h3>
          <div class="text-sm text-blue-700 space-y-1">
            <p><strong>Layer 1:</strong> Service (CrfSearch GenServer) → Direct PubSub broadcast</p>
            <p><strong>Layer 2:</strong> Phoenix.PubSub → LiveView subscription</p>
            <p><strong>Layer 3:</strong> LiveView → Immediate UI update</p>
            <p class="mt-3 font-medium">
              ✅ 3 layers total (vs 8+ in old architecture)<br />
              ✅ No telemetry middleware complexity<br /> ✅ Real-time updates with minimal latency
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # DRY service control with maps
  @sync_services %{
    "sonarr" => {&Reencodarr.Sync.sync_episodes/0, "Sonarr"},
    "radarr" => {&Reencodarr.Sync.sync_movies/0, "Radarr"}
  }

  defp sync_service(service, socket) do
    case socket.assigns.state.syncing do
      true ->
        {:noreply, put_flash(socket, :error, "Sync already in progress")}

      false ->
        {sync_func, name} = @sync_services[service]
        sync_func.()
        {:noreply, put_flash(socket, :info, "#{name} sync started")}
    end
  end

  # Service card component
  defp service_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow-lg p-6">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-semibold text-gray-900">{@name}</h3>
        <span class={"px-2 py-1 text-xs font-semibold rounded-full #{service_status_class(@status)}"}>
          {service_status_text(@status)}
        </span>
      </div>
      <div class="text-sm text-gray-600 mb-4">
        Queue: {@queue} videos
      </div>
      <div class="space-x-2">
        <button
          phx-click={"start_#{@service}"}
          class="bg-green-500 hover:bg-green-700 text-white text-sm px-3 py-1 rounded"
        >
          Start
        </button>
        <button
          phx-click={"pause_#{@service}"}
          class="bg-yellow-500 hover:bg-yellow-700 text-white text-sm px-3 py-1 rounded"
        >
          Pause
        </button>
      </div>
    </div>
    """
  end

  # Sync card component
  defp sync_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow-lg p-6">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-semibold text-gray-900">{@name}</h3>
        <span class={"px-2 py-1 text-xs font-semibold rounded-full #{sync_status_class(@syncing, @service_type, @service)}"}>
          {sync_status_text(@syncing, @service_type, @service)}
        </span>
      </div>
      <div class="text-sm text-gray-600 mb-4">
        {sync_status_description(@syncing, @progress, @service_type, @service)}
      </div>
      <div class="space-x-2">
        <button
          phx-click={"sync_#{@service}"}
          disabled={@syncing}
          class={"#{if @syncing, do: "bg-gray-400 cursor-not-allowed", else: "bg-blue-500 hover:bg-blue-700"} text-white text-sm px-3 py-1 rounded"}
        >
          Sync
        </button>
      </div>
    </div>
    """
  end

  # Helper functions for real data
  defp get_queue_counts do
    Reencodarr.PipelineStatus.get_all_queue_counts()
  end

  defp get_service_status do
    Reencodarr.PipelineStatus.get_all_service_status()
  end

  defp request_current_status do
    # Use shared status logic for all services
    Reencodarr.PipelineStatus.broadcast_current_status(:analyzer)
    Reencodarr.PipelineStatus.broadcast_current_status(:crf_searcher)
    Reencodarr.PipelineStatus.broadcast_current_status(:encoder)
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
    # Send async request to PerformanceMonitor via cast - it will respond via PubSub
    case GenServer.whereis(Reencodarr.Analyzer.Broadway.PerformanceMonitor) do
      # Process not running - throughput will remain nil
      nil -> :ok
      pid -> GenServer.cast(pid, {:throughput_request, self()})
    end
  end

  # Sync status helper functions
  defp sync_status_class(syncing, service_type, target_service) do
    cond do
      syncing && service_type == target_service -> "bg-blue-100 text-blue-800 animate-pulse"
      syncing && service_type != target_service -> "bg-gray-100 text-gray-600"
      not syncing -> "bg-gray-100 text-gray-800"
    end
  end

  defp sync_status_text(syncing, service_type, target_service) do
    cond do
      syncing && service_type == target_service -> "Syncing"
      syncing && service_type != target_service -> "Waiting"
      not syncing -> "Ready"
    end
  end

  defp sync_status_description(syncing, progress, service_type, target_service) do
    cond do
      syncing && service_type == target_service && progress > 0 ->
        "Progress: #{progress}%"

      syncing && service_type == target_service ->
        "Starting sync..."

      syncing && service_type != target_service ->
        "Another service syncing"

      not syncing ->
        "Ready to sync"
    end
  end
end
