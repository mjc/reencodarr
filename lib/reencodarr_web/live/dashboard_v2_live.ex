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
      # Start with running assumption for alive services, let actual events correct this
      service_status: get_optimistic_service_status(),
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
      # Request current status from all services with a small delay to let services initialize
      Process.send_after(self(), :request_status, 100)
      # Start periodic updates for queue counts and service status
      :timer.send_interval(5_000, self(), :update_dashboard_data)
    end

    {:noreply, socket}
  end

  # Helper function to safely get progress field values
  defp progress_field(progress, field, default \\ nil)
  defp progress_field(:none, _field, default), do: default

  defp progress_field(progress, field, default) when is_map(progress) do
    Map.get(progress, field, default)
  end

  # All handle_info callbacks grouped together
  @impl true
  def handle_info({:crf_search_started, _data}, socket) do
    # Don't create incomplete progress data - wait for actual progress events
    {:noreply, socket}
  end

  @impl true
  def handle_info({:crf_search_progress, data}, socket) do
    state = socket.assigns.state

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
          filename: data[:filename],
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

  # Completion and reset handlers
  @impl true
  def handle_info({event, _data}, socket) when event in [:crf_search_completed] do
    state = %{socket.assigns.state | crf_progress: :none}
    {:noreply, assign(socket, :state, state)}
  end

  # Special CRF search event handlers
  @impl true
  def handle_info({:crf_search_encoding_sample, data}, socket) do
    progress = %{filename: data.filename, crf: data.crf, percent: 0}
    state = %{socket.assigns.state | crf_progress: progress}
    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:crf_search_vmaf_result, data}, socket) do
    progress = %{filename: data.filename, crf: data.crf, score: data.score, percent: 100}
    state = %{socket.assigns.state | crf_progress: progress}
    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:analyzer_throughput, data}, socket) do
    state = socket.assigns.state

    updated_state = %{state | analyzer_throughput: data.throughput || 0.0}

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
    state = %{
      socket.assigns.state
      | syncing: true,
        sync_progress: 0,
        service_type: Map.get(data, :service_type)
    }

    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({:sync_progress, data}, socket) do
    progress = Map.get(data, :progress, 0)
    state = %{socket.assigns.state | sync_progress: progress}
    {:noreply, assign(socket, :state, state)}
  end

  @impl true
  def handle_info({sync_event, data}, socket)
      when sync_event in [:sync_completed, :sync_failed] do
    state = %{socket.assigns.state | syncing: false, sync_progress: 0, service_type: nil}

    socket =
      case sync_event do
        :sync_completed ->
          socket

        :sync_failed ->
          error = Map.get(data, :error, "Unknown error")
          put_flash(socket, :error, "Sync failed: #{inspect(error)}")
      end

    {:noreply, assign(socket, :state, state)}
  end

  # Service status handlers - grouped with other handle_info
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

  # Unified pipeline step component
  defp pipeline_step(assigns) do
    ~H"""
    <div class="text-center">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-gray-800">{@name}</h3>
        <span class={"px-2 py-1 text-xs rounded-full #{service_status_class(@status)}"}>
          {service_status_text(@status)}
        </span>
      </div>

      <div class="mb-3">
        <div class="text-2xl font-mono text-gray-600 mb-1">
          {@queue}
        </div>
        <div class="text-xs text-gray-500">queued</div>
      </div>

      <%= if @progress != :none do %>
        <div class="mb-3">
          <div class="w-full bg-gray-200 rounded-full h-2 mb-2">
            <div
              class={"bg-#{@color}-500 h-2 rounded-full transition-all duration-300"}
              style={"width: #{progress_field(@progress, :percent, 0)}%"}
            >
            </div>
          </div>
          <div class="text-sm text-gray-600">
            {progress_field(@progress, :percent, 0)}%
          </div>
        </div>
        <%= if progress_field(@progress, :filename) do %>
          <div class="text-xs text-gray-500 truncate mb-2">
            {Path.basename(progress_field(@progress, :filename))}
          </div>
        <% end %>
        {render_slot(@inner_block)}
      <% else %>
        <div class="text-xs text-gray-400 mb-3">Idle</div>
      <% end %>

      <div class="flex gap-2">
        <button
          phx-click={"start_#{@service}"}
          class="flex-1 bg-green-500 hover:bg-green-600 text-white text-xs py-1 px-2 rounded"
        >
          Start
        </button>
        <button
          phx-click={"pause_#{@service}"}
          class="flex-1 bg-yellow-500 hover:bg-yellow-600 text-white text-xs py-1 px-2 rounded"
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
      assign(
        assigns,
        :active,
        assigns.state.syncing && assigns.state.service_type == assigns.service
      )

    ~H"""
    <div class="text-center">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-gray-800">{@name}</h3>
        <span class={"px-2 py-1 text-xs rounded-full #{if @active, do: "bg-blue-100 text-blue-800 animate-pulse", else: "bg-gray-100 text-gray-600"}"}>
          {if @active, do: "Syncing", else: "Ready"}
        </span>
      </div>

      <%= if @active do %>
        <div class="mb-3">
          <div class="w-full bg-gray-200 rounded-full h-2 mb-2">
            <div
              class="bg-blue-500 h-2 rounded-full transition-all duration-300"
              style={"width: #{@state.sync_progress}%"}
            >
            </div>
          </div>
          <div class="text-sm text-gray-600">{@state.sync_progress}%</div>
        </div>
      <% else %>
        <div class="text-xs text-gray-400 mb-3">
          {if @state.syncing, do: "Waiting for other service", else: "Ready to sync"}
        </div>
      <% end %>

      <button
        phx-click={"sync_#{@service}"}
        disabled={@state.syncing}
        class={"w-full text-xs py-2 px-3 rounded #{if @state.syncing, do: "bg-gray-300 text-gray-500 cursor-not-allowed", else: "bg-blue-500 hover:bg-blue-600 text-white"}"}
      >
        Sync {@name}
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 p-6">
      <div class="max-w-7xl mx-auto space-y-6">
        <!-- Header -->
        <div>
          <h1 class="text-3xl font-bold text-gray-900">Video Processing Dashboard</h1>
          <p class="text-gray-600">Real-time status and controls for video transcoding pipeline</p>
        </div>
        
    <!-- Main Processing Pipeline -->
        <div class="bg-white rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-semibold mb-4">Processing Pipeline</h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
            <.pipeline_step
              name="Analysis"
              service="analyzer"
              status={@state.service_status.analyzer}
              queue={@state.queue_counts.analyzer}
              progress={@state.analyzer_progress}
              color="purple"
            >
              <%= if @state.analyzer_throughput && @state.analyzer_throughput > 0 do %>
                <div class="text-xs text-gray-500">
                  Rate: {Float.round(@state.analyzer_throughput, 1)} files/s
                </div>
              <% end %>
            </.pipeline_step>

            <.pipeline_step
              name="CRF Search"
              service="crf_searcher"
              status={@state.service_status.crf_searcher}
              queue={@state.queue_counts.crf_searcher}
              progress={@state.crf_progress}
              color="blue"
            >
              <%= if progress_field(@state.crf_progress, :crf) do %>
                <div class="text-xs text-gray-500">
                  CRF: {progress_field(@state.crf_progress, :crf)}
                  <%= if progress_field(@state.crf_progress, :score) do %>
                    | VMAF: {progress_field(@state.crf_progress, :score)}
                  <% end %>
                </div>
              <% end %>
            </.pipeline_step>

            <.pipeline_step
              name="Encoding"
              service="encoder"
              status={@state.service_status.encoder}
              queue={@state.queue_counts.encoder}
              progress={@state.encoding_progress}
              color="green"
            >
              <%= if progress_field(@state.encoding_progress, :fps) do %>
                <div class="text-xs text-gray-500">
                  {progress_field(@state.encoding_progress, :fps)} fps
                  <%= if progress_field(@state.encoding_progress, :eta) do %>
                    | ETA: {progress_field(@state.encoding_progress, :eta)} {progress_field(
                      @state.encoding_progress,
                      :time_unit
                    )}
                  <% end %>
                </div>
              <% end %>
            </.pipeline_step>
          </div>
        </div>
        
    <!-- External Sync Services -->
        <div class="bg-white rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-semibold mb-4">Media Library Sync</h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <.sync_service name="Sonarr" service={:sonarr} state={@state} />
            <.sync_service name="Radarr" service={:radarr} state={@state} />
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

  # Helper functions for real data
  defp get_queue_counts do
    Reencodarr.PipelineStatus.get_all_queue_counts()
  end

  # Optimistic service status - assume running if alive, let events correct it
  defp get_optimistic_service_status do
    %{
      analyzer:
        if(Process.whereis(Reencodarr.Analyzer.Broadway.Producer), do: :running, else: :stopped),
      crf_searcher:
        if(Process.whereis(Reencodarr.CrfSearcher.Broadway.Producer),
          do: :running,
          else: :stopped
        ),
      encoder:
        if(Process.whereis(Reencodarr.Encoder.Broadway.Producer), do: :running, else: :stopped)
    }
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
    case GenServer.whereis(Reencodarr.Analyzer.Broadway.PerformanceMonitor) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:throughput_request, self()})
    end
  end
end
