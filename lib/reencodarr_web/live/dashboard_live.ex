defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Attach telemetry handler for dashboard state updates
    if connected?(socket) do
      :telemetry.attach_many(
        "dashboard-#{inspect(self())}",
        [[:reencodarr, :dashboard, :state_updated]],
        &__MODULE__.handle_telemetry_event/4,
        %{live_view_pid: self()}
      )
    end

    initial_state = get_initial_state()

    socket =
      assign(socket,
        state: initial_state,
        timezone: socket.assigns[:timezone] || "UTC"
      )

    {:ok, socket}
  end

  @impl true
  def handle_info({:telemetry_event, state}, socket) do
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
      class="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 p-6"
      phx-hook="TimezoneHook"
    >
      <!-- Header Section -->
      <header class="mb-8">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6">
            <div>
              <h1 class="text-4xl lg:text-5xl font-extrabold bg-gradient-to-r from-cyan-400 to-blue-500 bg-clip-text text-transparent mb-2">
                Reencodarr
              </h1>
              <p class="text-slate-300 text-lg">
                Intelligent Video Encoding Pipeline
              </p>
            </div>

            <!-- Control Panel -->
            <div class="flex flex-wrap gap-3">
              <.render_control_buttons
                encoding={@state.encoding}
                crf_searching={@state.crf_searching}
                syncing={@state.syncing}
              />
            </div>
          </div>
        </div>
      </header>

      <div class="max-w-7xl mx-auto space-y-8">
        <!-- Key Metrics Hero Section -->
        <section class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          <.metric_card
            title="Total Videos"
            value={@state.stats.total_videos}
            icon="📹"
            color="from-blue-500 to-cyan-500"
            subtitle="in library"
          />

          <.metric_card
            title="Reencoded"
            value={@state.stats.reencoded}
            icon="✨"
            color="from-emerald-500 to-teal-500"
            subtitle="optimized"
            progress={calculate_progress(@state.stats.reencoded, @state.stats.total_videos)}
          />

          <.metric_card
            title="VMAF Quality"
            value={"#{@state.stats.avg_vmaf_percentage}%"}
            icon="🎯"
            color="from-violet-500 to-purple-500"
            subtitle="average"
          />

          <.metric_card
            title="Queue Length"
            value={@state.stats.queue_length.crf_searches + @state.stats.queue_length.encodes}
            icon="⏳"
            color="from-amber-500 to-orange-500"
            subtitle="pending jobs"
          />
        </section>

        <!-- Status and Progress Section -->
        <section class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Real-time Status -->
          <div class="lg:col-span-2">
            <.status_panel
              encoding={@state.encoding}
              crf_searching={@state.crf_searching}
              syncing={@state.syncing}
              encoding_progress={@state.encoding_progress}
              crf_search_progress={@state.crf_search_progress}
              sync_progress={@state.sync_progress}
            />
          </div>

          <!-- Quick Stats -->
          <div class="space-y-4">
            <.stats_sidebar stats={@state.stats} timezone={@timezone} />
          </div>
        </section>

        <!-- Queue Visualization -->
        <section class="grid grid-cols-1 xl:grid-cols-2 gap-6">
          <.enhanced_queue_display
            title="CRF Search Queue"
            files={@state.next_crf_search}
            icon="🔍"
            color="from-cyan-500 to-blue-500"
          />

          <.enhanced_queue_display
            title="Encoding Queue"
            files={@state.videos_by_estimated_percent}
            icon="⚡"
            color="from-emerald-500 to-teal-500"
          />
        </section>

        <!-- Manual Scan Section -->
        <section>
          <.enhanced_manual_scan />
        </section>
      </div>

      <!-- Footer -->
      <footer class="mt-16 text-center text-slate-400 text-sm">
        <div class="max-w-7xl mx-auto border-t border-slate-700 pt-8">
          <p>
            Reencodarr &copy; 2024 &mdash;
            <a href="https://github.com/mjc/reencodarr" class="text-cyan-400 hover:text-cyan-300 transition-colors">
              GitHub
            </a>
          </p>
        </div>
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

  # Manual Scan Form
  def render_manual_scan_form(assigns) do
    ~H"""
    <.live_component module={ReencodarrWeb.ManualScanComponent} id="manual-scan" />
    """
  end

  # Telemetry event handler
  def handle_telemetry_event([:reencodarr, :dashboard, :state_updated], _measurements, %{state: state}, %{live_view_pid: pid}) do
    send(pid, {:telemetry_event, state})
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dashboard-#{inspect(self())}")
    :ok
  end

  # Helper function to safely get initial state, with fallback for test environment
  defp get_initial_state do
    try do
      Reencodarr.TelemetryReporter.get_current_state()
    catch
      :exit, _ ->
        # Return a default dashboard state for tests
        Reencodarr.DashboardState.initial()
    end
  end

  # Enhanced UI Components

  def metric_card(assigns) do
    ~H"""
    <div class="relative overflow-hidden rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6 hover:bg-white/10 transition-all duration-300">
      <div class="flex items-start justify-between">
        <div class="flex-1">
          <div class="flex items-center gap-3 mb-2">
            <span class="text-2xl">{@icon}</span>
            <h3 class="text-slate-200 text-sm font-semibold">{@title}</h3>
          </div>
          <p class="text-3xl font-bold text-white mb-1">{@value}</p>
          <p class="text-slate-300 text-xs font-medium">{@subtitle}</p>
        </div>

        <!-- Progress Ring (if provided) -->
        <%= if assigns[:progress] do %>
          <div class="relative w-12 h-12">
            <svg class="w-12 h-12 transform -rotate-90" viewBox="0 0 36 36">
              <path
                class="text-slate-700"
                stroke="currentColor"
                stroke-width="3"
                fill="none"
                d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
              />
              <path
                class="text-cyan-400"
                stroke="currentColor"
                stroke-width="3"
                stroke-linecap="round"
                fill="none"
                stroke-dasharray={"#{@progress}, 100"}
                d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
              />
            </svg>
            <div class="absolute inset-0 flex items-center justify-center text-xs text-white font-semibold">
              {round(@progress)}%
            </div>
          </div>
        <% end %>
      </div>

      <!-- Gradient overlay -->
      <div class={"absolute top-0 left-0 w-full h-1 bg-gradient-to-r #{@color}"}></div>
    </div>
    """
  end

  def status_panel(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
      <h2 class="text-xl font-semibold text-white mb-6 flex items-center gap-2">
        <span class="text-xl">⚡</span>
        Real-time Status
      </h2>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <!-- Encoding Status -->
        <div class="space-y-3">
          <div class="flex items-center justify-between">
            <span class="text-slate-200 text-sm font-semibold">Encoding</span>
            <.status_indicator active={@encoding} />
          </div>
          <%= if @encoding and map_size(@encoding_progress) > 0 do %>
            <.progress_bar
              label="Progress"
              value={@encoding_progress.percent || 0}
              color="from-emerald-500 to-teal-500"
            />
            <%= if @encoding_progress.filename do %>
              <p class="text-xs text-slate-300 truncate font-medium" title={@encoding_progress.filename}>
                {Path.basename(@encoding_progress.filename)}
              </p>
            <% end %>
          <% end %>
        </div>

        <!-- CRF Search Status -->
        <div class="space-y-3">
          <div class="flex items-center justify-between">
            <span class="text-slate-200 text-sm font-semibold">CRF Search</span>
            <.status_indicator active={@crf_searching} />
          </div>
          <%= if @crf_searching and map_size(@crf_search_progress) > 0 do %>
            <.progress_bar
              label="Progress"
              value={@crf_search_progress.percent || 0}
              color="from-blue-500 to-cyan-500"
            />
            <%= if @crf_search_progress.filename do %>
              <p class="text-xs text-slate-300 truncate font-medium" title={@crf_search_progress.filename}>
                {Path.basename(@crf_search_progress.filename)}
              </p>
            <% end %>
          <% end %>
        </div>

        <!-- Sync Status -->
        <div class="space-y-3">
          <div class="flex items-center justify-between">
            <span class="text-slate-200 text-sm font-semibold">Sync</span>
            <.status_indicator active={@syncing} />
          </div>
          <%= if @syncing and @sync_progress > 0 do %>
            <.progress_bar
              label="Syncing..."
              value={@sync_progress}
              color="from-violet-500 to-purple-500"
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def status_indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <div class={[
        "w-2 h-2 rounded-full",
        if(@active, do: "bg-emerald-400 animate-pulse", else: "bg-slate-600")
      ]}></div>
      <span class={[
        "text-xs font-semibold",
        if(@active, do: "text-emerald-300", else: "text-slate-400")
      ]}>
        {if @active, do: "Active", else: "Idle"}
      </span>
    </div>
    """
  end

  def progress_bar(assigns) do
    assigns = assign_new(assigns, :value, fn -> 0 end)

    ~H"""
    <div class="space-y-1">
      <div class="flex justify-between text-xs">
        <span class="text-slate-300 font-medium">{@label}</span>
        <span class="text-slate-100 font-semibold">{@value}%</span>
      </div>
      <div class="w-full bg-slate-700 rounded-full h-2 overflow-hidden">
        <div
          class={"h-full bg-gradient-to-r #{@color} transition-all duration-300 ease-out"}
          style={"width: #{@value}%"}
        ></div>
      </div>
    </div>
    """
  end

  def stats_sidebar(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
      <h3 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <span class="text-lg">📊</span>
        Quick Stats
      </h3>

      <div class="space-y-4">
        <.stat_item
          label="Total VMAFs"
          value={@stats.total_vmafs}
          icon="🎯"
        />

        <.stat_item
          label="Chosen VMAFs"
          value={@stats.chosen_vmafs_count}
          icon="✅"
        />

        <div class="border-t border-white/10 pt-4">
          <.stat_item
            label="Last Video Update"
            value={human_readable_time(@stats.most_recent_video_update, @timezone)}
            icon="🕒"
            small={true}
          />

          <.stat_item
            label="Last Video Insert"
            value={human_readable_time(@stats.most_recent_inserted_video, @timezone)}
            icon="📥"
            small={true}
          />
        </div>
      </div>
    </div>
    """
  end

  def stat_item(assigns) do
    assigns = assign_new(assigns, :small, fn -> false end)

    ~H"""
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class={if(@small, do: "text-sm", else: "text-base")}>{@icon}</span>
        <span class={[
          "text-slate-200",
          if(@small, do: "text-xs", else: "text-sm")
        ]}>{@label}</span>
      </div>
      <span class={[
        "font-semibold text-white",
        if(@small, do: "text-xs", else: "text-sm")
      ]}>{@value}</span>
    </div>
    """
  end

  def enhanced_queue_display(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
      <div class="flex items-center justify-between mb-6">
        <h3 class="text-lg font-semibold text-white flex items-center gap-2">
          <span class="text-lg">{@icon}</span>
          {@title}
        </h3>
        <span class="text-sm text-slate-300 bg-white/10 px-3 py-1 rounded-full font-medium">
          {length(@files)} items
        </span>
      </div>

      <%= if @files == [] do %>
        <div class="text-center py-8">
          <div class="text-4xl mb-2">🎉</div>
          <p class="text-slate-400">Queue is empty!</p>
        </div>
      <% else %>
        <div class="space-y-3 max-h-60 overflow-y-auto">
          <%= for {file, index} <- Enum.with_index(Enum.take(@files, 10)) do %>
            <div class="flex items-center gap-3 p-3 rounded-lg bg-white/5 hover:bg-white/10 transition-colors">
              <div class={[
                "w-8 h-8 rounded-full flex items-center justify-center text-xs font-semibold",
                "bg-gradient-to-r #{@color} text-white"
              ]}>
                {index + 1}
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm text-white truncate" title={get_file_path(file)}>
                  {Path.basename(get_file_path(file))}
                </p>
                <%= if get_estimated_percent(file) do %>
                  <p class="text-xs text-slate-400">
                    ~{get_estimated_percent(file)}% complete
                  </p>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if length(@files) > 10 do %>
            <div class="text-center py-2">
              <span class="text-xs text-slate-400">
                +{length(@files) - 10} more items
              </span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def enhanced_manual_scan(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
      <h3 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <span class="text-lg">🔍</span>
        Manual Scan
      </h3>
      <.live_component module={ReencodarrWeb.ManualScanComponent} id="manual-scan" />
    </div>
    """
  end

  # Helper function to calculate progress percentage
  defp calculate_progress(completed, total) when total > 0 do
    (completed / total * 100) |> Float.round(1)
  end
  defp calculate_progress(_, _), do: 0

  # Helper function for human readable time (keeping existing logic)
  defp human_readable_time(nil, _timezone), do: "Never"
  defp human_readable_time(datetime, timezone) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> human_readable_time(dt, timezone)
      _ -> "Invalid date"
    end
  end
  defp human_readable_time(%DateTime{} = datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} ->
        shifted
        |> DateTime.to_date()
        |> Date.to_string()
      _ ->
        datetime
        |> DateTime.to_date()
        |> Date.to_string()
    end
  end
  defp human_readable_time(datetime, _), do: inspect(datetime)

  # Helper functions to extract data from file structs
  defp get_file_path(%{video: %{path: path}}) when is_binary(path), do: path
  defp get_file_path(%{path: path}) when is_binary(path), do: path
  defp get_file_path(_), do: "Unknown"

  defp get_estimated_percent(file) do
    Map.get(file, :estimated_percent, nil)
  rescue
    _ -> nil
  end
end
