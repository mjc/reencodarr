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
            service_status: %{analyzer: :unknown, crf_searcher: :unknown, encoder: :unknown}

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

    updated_state = %{
      state
      | crf_progress: %{
          percent: data.percent || 0,
          filename: data.filename,
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
  def handle_info({:encoding_progress, data}, socket) do
    state = socket.assigns.state

    updated_state = %{
      state
      | encoding_progress: %{
          percent: data.percent,
          fps: data.fps,
          eta: data.eta,
          time_unit: data.time_unit,
          timestamp: data.timestamp,
          video_id: data.video_id
        }
    }

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:analyzer_progress, data}, socket) do
    state = socket.assigns.state

    updated_state = %{
      state
      | analyzer_progress: %{
          percent: data.percent || 0,
          count: data.count,
          total: data.total
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
  def handle_info(:update_dashboard_data, socket) do
    state = socket.assigns.state

    updated_state = %{
      state
      | queue_counts: get_queue_counts()
    }

    # Request updated status async (don't block)
    request_async_service_status()
    # Request updated throughput async (don't block)
    request_analyzer_throughput()

    {:noreply, assign(socket, :state, updated_state)}
  end

  @impl true
  def handle_info({:status_response, service, status}, socket) do
    state = socket.assigns.state

    updated_service_status = Map.put(state.service_status, service, status)
    updated_state = %{state | service_status: updated_service_status}

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

  @impl true
  def handle_event("pause_analyzer", _params, socket) do
    Reencodarr.Analyzer.Broadway.Producer.pause()
    {:noreply, put_flash(socket, :info, "Analyzer paused")}
  end

  @impl true
  def handle_event("start_crf_searcher", _params, socket) do
    Reencodarr.CrfSearcher.Broadway.Producer.start()
    {:noreply, put_flash(socket, :info, "CRF Searcher started")}
  end

  @impl true
  def handle_event("pause_crf_searcher", _params, socket) do
    Reencodarr.CrfSearcher.Broadway.Producer.pause()
    {:noreply, put_flash(socket, :info, "CRF Searcher paused")}
  end

  @impl true
  def handle_event("start_encoder", _params, socket) do
    Reencodarr.Encoder.Broadway.Producer.start()
    {:noreply, put_flash(socket, :info, "Encoder started")}
  end

  @impl true
  def handle_event("pause_encoder", _params, socket) do
    Reencodarr.Encoder.Broadway.Producer.pause()
    {:noreply, put_flash(socket, :info, "Encoder paused")}
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
        
    <!-- Service Status and Controls -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-6">
          <!-- Analyzer Status -->
          <div class="bg-white rounded-lg shadow-lg p-6">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold text-gray-900">Analyzer</h3>
              <span class={"px-2 py-1 text-xs font-semibold rounded-full #{service_status_class(@state.service_status.analyzer)}"}>
                {@state.service_status.analyzer}
              </span>
            </div>
            <div class="text-sm text-gray-600 mb-4">
              Queue: {@state.queue_counts.analyzer} videos
            </div>
            <div class="space-x-2">
              <button
                phx-click="start_analyzer"
                class="bg-green-500 hover:bg-green-700 text-white text-sm px-3 py-1 rounded"
              >
                Start
              </button>
              <button
                phx-click="pause_analyzer"
                class="bg-yellow-500 hover:bg-yellow-700 text-white text-sm px-3 py-1 rounded"
              >
                Pause
              </button>
            </div>
          </div>
          
    <!-- CRF Searcher Status -->
          <div class="bg-white rounded-lg shadow-lg p-6">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold text-gray-900">CRF Searcher</h3>
              <span class={"px-2 py-1 text-xs font-semibold rounded-full #{service_status_class(@state.service_status.crf_searcher)}"}>
                {@state.service_status.crf_searcher}
              </span>
            </div>
            <div class="text-sm text-gray-600 mb-4">
              Queue: {@state.queue_counts.crf_searcher} videos
            </div>
            <div class="space-x-2">
              <button
                phx-click="start_crf_searcher"
                class="bg-green-500 hover:bg-green-700 text-white text-sm px-3 py-1 rounded"
              >
                Start
              </button>
              <button
                phx-click="pause_crf_searcher"
                class="bg-yellow-500 hover:bg-yellow-700 text-white text-sm px-3 py-1 rounded"
              >
                Pause
              </button>
            </div>
          </div>
          
    <!-- Encoder Status -->
          <div class="bg-white rounded-lg shadow-lg p-6">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold text-gray-900">Encoder</h3>
              <span class={"px-2 py-1 text-xs font-semibold rounded-full #{service_status_class(@state.service_status.encoder)}"}>
                {@state.service_status.encoder}
              </span>
            </div>
            <div class="text-sm text-gray-600 mb-4">
              Queue: {@state.queue_counts.encoder} videos
            </div>
            <div class="space-x-2">
              <button
                phx-click="start_encoder"
                class="bg-green-500 hover:bg-green-700 text-white text-sm px-3 py-1 rounded"
              >
                Start
              </button>
              <button
                phx-click="pause_encoder"
                class="bg-yellow-500 hover:bg-yellow-700 text-white text-sm px-3 py-1 rounded"
              >
                Pause
              </button>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <!-- Analyzer Progress -->
          <div class="bg-white rounded-lg shadow-lg p-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold text-gray-900">Analysis</h2>
              <div class={"w-3 h-3 rounded-full #{if @state.analyzer_progress != :none, do: "bg-green-400 animate-pulse", else: "bg-gray-300"}"}>
              </div>
            </div>

            <%= if @state.analyzer_progress != :none do %>
              <div class="space-y-3">
                <div class="flex justify-between items-center">
                  <span class="text-sm font-medium text-gray-700">Progress</span>
                  <span class="text-sm font-mono text-gray-900">
                    {progress_field(@state.analyzer_progress, :percent)}%
                  </span>
                </div>

                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-purple-500 h-2 rounded-full transition-all duration-300 ease-out"
                    style={"width: #{progress_field(@state.analyzer_progress, :percent)}%"}
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
              </div>
            <% else %>
              <div class="text-center py-8">
                <div class="text-gray-400 text-sm">No active analysis</div>
                <%= if @state.analyzer_throughput && @state.analyzer_throughput > 0 do %>
                  <div class="text-xs text-gray-500 mt-1">
                    Last rate: {Float.round(@state.analyzer_throughput, 1)} files/s
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
          
    <!-- CRF Search Progress -->
          <div class="bg-white rounded-lg shadow-lg p-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold text-gray-900">CRF Search</h2>
              <div class={"w-3 h-3 rounded-full #{if @state.crf_progress != :none, do: "bg-green-400 animate-pulse", else: "bg-gray-300"}"}>
              </div>
            </div>

            <%= if @state.crf_progress != :none do %>
              <div class="space-y-3">
                <div class="flex justify-between items-center">
                  <span class="text-sm font-medium text-gray-700">Progress</span>
                  <span class="text-sm font-mono text-gray-900">
                    {progress_field(@state.crf_progress, :percent)}%
                  </span>
                </div>

                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-blue-500 h-2 rounded-full transition-all duration-300 ease-out"
                    style={"width: #{progress_field(@state.crf_progress, :percent)}%"}
                  >
                  </div>
                </div>

                <%= if @state.crf_progress.filename do %>
                  <div class="text-xs text-gray-500 truncate">
                    {Path.basename(@state.crf_progress.filename)}
                  </div>
                <% end %>

                <%= if progress_field(@state.crf_progress, :crf) do %>
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-600">
                      CRF: {progress_field(@state.crf_progress, :crf)}
                    </span>
                    <%= if progress_field(@state.crf_progress, :score) do %>
                      <span class="text-gray-600">
                        VMAF: {progress_field(@state.crf_progress, :score)}
                      </span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-center py-8">
                <div class="text-gray-400 text-sm">No active CRF search</div>
              </div>
            <% end %>
          </div>
          
    <!-- Encoding Progress -->
          <div class="bg-white rounded-lg shadow-lg p-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold text-gray-900">Encoding</h2>
              <div class={"w-3 h-3 rounded-full #{if @state.encoding_progress != :none, do: "bg-green-400 animate-pulse", else: "bg-gray-300"}"}>
              </div>
            </div>

            <%= if @state.encoding_progress != :none do %>
              <div class="space-y-3">
                <%= if progress_field(@state.encoding_progress, :video_id) do %>
                  <div class="text-xs text-gray-500 truncate">
                    Video ID: {progress_field(@state.encoding_progress, :video_id)}
                  </div>
                <% end %>

                <div class="flex justify-between items-center">
                  <span class="text-sm font-medium text-gray-700">Progress</span>
                  <span class="text-sm font-mono text-gray-900">
                    {progress_field(@state.encoding_progress, :percent)}%
                  </span>
                </div>

                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-green-500 h-2 rounded-full transition-all duration-300 ease-out"
                    style={"width: #{progress_field(@state.encoding_progress, :percent)}%"}
                  >
                  </div>
                </div>

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
              </div>
            <% else %>
              <div class="text-center py-8">
                <div class="text-gray-400 text-sm">No active encoding</div>
              </div>
            <% end %>
          </div>
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

  # Helper functions for real data
  defp get_queue_counts do
    %{
      analyzer: count_videos_needing_analysis(),
      crf_searcher: count_videos_needing_crf_search(),
      encoder: count_videos_needing_encoding()
    }
  end

  defp get_service_status do
    # Request async status updates - they'll arrive via PubSub
    request_async_service_status()

    # Return initial unknown states - will be updated when responses arrive
    %{
      analyzer: :checking,
      crf_searcher: :checking,
      encoder: :checking
    }
  end

  defp request_async_service_status do
    # Request status from all services asynchronously
    request_analyzer_status()
    request_crf_searcher_status()
    request_encoder_status()
  end

  defp request_crf_searcher_status do
    case GenServer.whereis(Reencodarr.CrfSearcher.Broadway.Producer) do
      # Process not running
      nil -> :ok
      pid -> GenServer.cast(pid, {:status_request, self()})
    end
  end

  defp request_encoder_status do
    case GenServer.whereis(Reencodarr.Encoder.Broadway.Producer) do
      # Process not running
      nil -> :ok
      pid -> GenServer.cast(pid, {:status_request, self()})
    end
  end

  defp request_analyzer_status do
    case GenServer.whereis(Reencodarr.Analyzer.Broadway.Producer) do
      # Process not running
      nil -> :ok
      pid -> GenServer.cast(pid, {:status_request, self()})
    end
  end

  defp count_videos_needing_analysis do
    Reencodarr.Media.count_videos_needing_analysis()
  rescue
    _ -> 0
  end

  defp count_videos_needing_crf_search do
    Reencodarr.Media.count_videos_for_crf_search()
  rescue
    _ -> 0
  end

  defp count_videos_needing_encoding do
    # Use a query to count videos in crf_searched state
    import Ecto.Query

    Reencodarr.Repo.aggregate(
      from(v in Reencodarr.Media.Video, where: v.state == :crf_searched),
      :count
    )
  rescue
    _ -> 0
  end

  defp service_status_class(:running), do: "bg-green-100 text-green-800"
  defp service_status_class(:paused), do: "bg-yellow-100 text-yellow-800"
  defp service_status_class(:processing), do: "bg-blue-100 text-blue-800"
  defp service_status_class(:pausing), do: "bg-orange-100 text-orange-800"
  defp service_status_class(:idle), do: "bg-cyan-100 text-cyan-800"
  defp service_status_class(:checking), do: "bg-gray-100 text-gray-600 animate-pulse"
  defp service_status_class(:stopped), do: "bg-red-100 text-red-800"
  defp service_status_class(:unknown), do: "bg-gray-100 text-gray-800"

  # Convert status atoms to user-friendly text
  defp service_status_text(:running), do: "Running"
  defp service_status_text(:paused), do: "Paused"
  defp service_status_text(:processing), do: "Processing"
  defp service_status_text(:pausing), do: "Pausing"
  defp service_status_text(:idle), do: "Idle"
  defp service_status_text(:checking), do: "Checking..."
  defp service_status_text(:stopped), do: "Stopped"
  defp service_status_text(:unknown), do: "Unknown"

  defp request_analyzer_throughput do
    # Send async request to PerformanceMonitor via cast - it will respond via PubSub
    case GenServer.whereis(Reencodarr.Analyzer.Broadway.PerformanceMonitor) do
      # Process not running - throughput will remain nil
      nil -> :ok
      pid -> GenServer.cast(pid, {:throughput_request, self()})
    end
  end
end
