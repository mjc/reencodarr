defmodule ReencodarrWeb.DashboardComponents do
  @moduledoc """
  Specific components for the main dashboard overview.

  Contains the operations panel, queues section, and other components
  specific to the overview dashboard functionality.
  """

  use Phoenix.Component
  import ReencodarrWeb.LcarsComponents
  alias Reencodarr.Formatters

  @doc """
  Renders the metrics grid with all metric cards.
  """
  attr :metrics, :list, required: true

  def metrics_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
      <%= for metric <- @metrics do %>
        <.lcars_metric_card metric={metric} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the operations status panel.
  """
  attr :status, :map, required: true

  def operations_panel(assigns) do
    ~H"""
    <div class="bg-gray-900 border-2 border-yellow-400 rounded-lg overflow-hidden h-64 sm:h-72 flex flex-col">
      <div class="h-10 sm:h-12 bg-yellow-400 flex items-center px-3 sm:px-4 flex-shrink-0">
        <span class="text-black font-bold tracking-wider text-sm sm:text-base">
          SYSTEM OPERATIONS
        </span>
      </div>

      <div class="p-3 sm:p-4 grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4 flex-1 overflow-hidden">
        <.operation_status
          title="CRF SEARCH"
          active={@status.crf_searching.active}
          progress={@status.crf_searching.progress}
          color="purple"
        />
        <.operation_status
          title="ENCODING"
          active={@status.encoding.active}
          progress={@status.encoding.progress}
          color="blue"
        />
        <.operation_status
          title="ANALYZER"
          active={@status.analyzing.active}
          progress={@status.analyzing.progress}
          color="green"
        />
        <.operation_status
          title="SYNC"
          active={@status.syncing.active}
          progress={@status.syncing.progress}
          color="red"
        />
      </div>
    </div>
    """
  end

  defp operation_status(assigns) do
    ~H"""
    <div class="space-y-2 sm:space-y-3">
      <div class={[
        "h-6 sm:h-8 rounded-r-full flex items-center px-2 sm:px-3",
        operation_color(@color)
      ]}>
        <span class="text-black font-bold tracking-wider text-xs sm:text-sm truncate">{@title}</span>
      </div>

      <div class="space-y-1 sm:space-y-2">
        <div class="flex items-center space-x-2">
          <div class={[
            "w-2 h-2 sm:w-3 sm:h-3 rounded-full",
            if(@active, do: "bg-green-400 animate-pulse", else: "bg-gray-600")
          ]}>
          </div>
          <span class={[
            "text-xs sm:text-sm font-bold tracking-wide",
            if(@active, do: "text-green-400", else: "text-gray-500")
          ]}>
            {if @active, do: "ONLINE", else: "STANDBY"}
          </span>
        </div>

        <.operation_progress title={@title} active={@active} progress={@progress} color={@color} />
      </div>
    </div>
    """
  end

  defp operation_progress(%{title: "ANALYZER"} = assigns) do
    ~H"""
    <!-- Analyzer stats without progress bar -->
    <div class="space-y-1">
      <div class="text-xs text-orange-300 space-y-1">
        <div class="flex justify-between">
          <span>Rate Limit: {Map.get(@progress, :rate_limit, 0)}</span>
          <span>Batch Size: {Map.get(@progress, :batch_size, 0)}</span>
        </div>
        <div class="text-center">
          <span>{Map.get(@progress, :throughput, 0.0)} msg/s</span>
        </div>
      </div>
    </div>
    """
  end

  defp operation_progress(assigns) do
    ~H"""
    <!-- Regular progress section for other components -->
    <%= if should_show_progress?(@active, @progress, @title) do %>
      <div class="space-y-1">
        <%= if @progress.filename do %>
          <div class="text-xs text-orange-300 tracking-wide truncate">
            {String.upcase(to_string(@progress.filename))}
          </div>
        <% end %>
        <div class="h-1.5 sm:h-2 bg-gray-800 rounded-full overflow-hidden">
          <div
            class={[
              "h-full transition-all duration-500",
              progress_color(@color)
            ]}
            style={"width: #{get_progress_percent(@progress)}%"}
          >
          </div>
        </div>
        <div class="flex justify-between text-xs text-orange-300">
          <span>{get_progress_percent(@progress)}%</span>
          <%= cond do %>
            <% Map.get(@progress, :throughput) && @progress.throughput > 0 -> %>
              <span>{@progress.throughput} msg/s</span>
            <% Map.get(@progress, :fps) && @progress.fps > 0 -> %>
              <span>{Formatters.format_fps(@progress.fps)} FPS</span>
            <% true -> %>
              <span></span>
          <% end %>
        </div>
        <%= if Map.get(@progress, :eta) && @progress.eta != 0 do %>
          <div class="text-xs text-orange-400 text-center">
            ETA: {Formatters.format_eta(@progress.eta)}
          </div>
        <% end %>
        <%= if Map.get(@progress, :crf) && Map.get(@progress, :score) do %>
          <div class="flex justify-between text-xs text-orange-400">
            <span>CRF: {Formatters.format_crf(@progress.crf)}</span>
            <span>VMAF: {Formatters.format_vmaf_score(@progress.score)}</span>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders the queues section with stream-based queue panels.
  """
  attr :queues, :map, required: true
  attr :streams, :map, required: true

  def queues_section(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-3 sm:gap-4">
      <.queue_panel
        title="CRF SEARCH QUEUE"
        queue={@queues.crf_search}
        queue_stream={@streams.crf_search_queue}
        color="cyan"
      />
      <.queue_panel
        title="ENCODING QUEUE"
        queue={@queues.encoding}
        queue_stream={@streams.encoding_queue}
        color="green"
      />
      <.queue_panel
        title="ANALYZER QUEUE"
        queue={@queues.analyzer}
        queue_stream={@streams.analyzer_queue}
        color="purple"
      />
    </div>
    """
  end

  defp queue_panel(assigns) do
    ~H"""
    <div class="bg-gray-900 border-2 border-cyan-400 rounded-lg overflow-hidden">
      <div class={[
        "h-8 sm:h-10 flex items-center px-2 sm:px-3",
        queue_header_color(@color)
      ]}>
        <span class="text-black font-bold tracking-wider text-xs sm:text-sm truncate flex-1">
          {@title}
        </span>
        <div class="ml-2">
          <span class="text-black font-bold text-xs sm:text-sm">
            {Formatters.format_count(@queue.total_count)}
          </span>
        </div>
      </div>

      <div class="p-2 sm:p-3">
        <%= if @queue.total_count == 0 do %>
          <div class="text-center py-4 sm:py-6">
            <div class="text-3xl sm:text-4xl mb-2">🎉</div>
            <p class="text-orange-300 tracking-wide text-xs sm:text-sm">QUEUE EMPTY</p>
          </div>
        <% else %>
          <div
            class="space-y-1 sm:space-y-2 max-h-48 sm:max-h-64 overflow-y-auto"
            id={"#{@color}-queue-container"}
          >
            <div phx-update="stream" id={"#{@color}-queue-items"}>
              <%= for {item_id, file} <- (@queue_stream || []) do %>
                <div id={item_id}>
                  <.queue_file_item file={file} queue={@queue} />
                </div>
              <% end %>
            </div>

            <%= if @queue.total_count > 10 do %>
              <div class="text-center py-1 sm:py-2">
                <span class="text-xs text-orange-300 tracking-wide">
                  SHOWING FIRST 10 OF {Formatters.format_count(@queue.total_count)} ITEMS
                </span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp queue_file_item(assigns) do
    ~H"""
    <div class="flex items-center space-x-2 sm:space-x-3 p-2 sm:p-3 bg-gray-800 rounded border-l-2 sm:border-l-4 border-orange-500">
      <div class="w-6 h-6 sm:w-8 sm:h-8 bg-orange-500 rounded-full flex items-center justify-center flex-shrink-0">
        <span class="text-black font-bold text-xs sm:text-sm">{@file.index}</span>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-orange-300 text-xs sm:text-sm tracking-wide truncate font-mono">
          {String.upcase(@file.display_name)}
        </p>
        <%= if @file.estimated_percent do %>
          <p class="text-xs text-orange-400">
            EST: ~{@file.estimated_percent}%
          </p>
        <% end %>
        <.queue_specific_info file={@file} queue={@queue} />
      </div>
    </div>
    """
  end

  defp queue_specific_info(assigns) do
    ~H"""
    <%= cond do %>
      <% @queue.title == "CRF Search Queue" and (@file.bitrate || @file.size) -> %>
        <div class="flex justify-between text-xs text-cyan-300 mt-1">
          <%= if @file.bitrate do %>
            <span>Bitrate: {Formatters.format_bitrate_mbps(@file.bitrate)}</span>
          <% end %>
          <%= if @file.size do %>
            <span>Size: {Formatters.format_file_size(@file.size)}</span>
          <% end %>
        </div>
      <% @queue.title == "Encoding Queue" and (@file.estimated_savings_bytes || @file.size) -> %>
        <div class="flex justify-between text-xs text-green-300 mt-1">
          <%= if @file.estimated_savings_bytes do %>
            <span>Savings: {Formatters.format_savings_bytes(@file.estimated_savings_bytes)}</span>
          <% end %>
          <%= if @file.size do %>
            <span>Size: {Formatters.format_file_size(@file.size)}</span>
          <% end %>
        </div>
      <% @queue.title == "Analyzer Queue" and @file.size -> %>
        <div class="text-xs text-purple-300 mt-1">
          Size: {Formatters.format_file_size(@file.size)}
        </div>
      <% true -> %>
        <div></div>
    <% end %>
    """
  end

  @doc """
  Renders the control panel with statistics and operations.
  """
  attr :status, :map, required: true
  attr :stats, :map, required: true

  def control_panel(assigns) do
    ~H"""
    <.lcars_panel title="CONTROL PANEL" color="green">
      <div class="space-y-3 sm:space-y-4">
        <div class="space-y-2">
          <div class="text-orange-300 text-xs sm:text-sm font-bold tracking-wide">STATISTICS</div>
          <div class="grid grid-cols-2 gap-2 text-xs">
            <.lcars_stat_row label="TOTAL VMAFS" value={Formatters.format_count(@stats.total_vmafs)} />
            <.lcars_stat_row
              label="CHOSEN VMAFS"
              value={Formatters.format_count(@stats.chosen_vmafs_count)}
            />
            <.lcars_stat_row label="LAST UPDATE" value={@stats.last_video_update} small={true} />
            <.lcars_stat_row label="LAST INSERT" value={@stats.last_video_insert} small={true} />
          </div>
        </div>

        <div class="space-y-2">
          <div class="text-orange-300 text-xs sm:text-sm font-bold tracking-wide">OPERATIONS</div>
          <.live_component
            module={ReencodarrWeb.ControlButtonsComponent}
            id="control-buttons"
            encoding={@status.encoding.active}
            crf_searching={@status.crf_searching.active}
            analyzing={@status.analyzing.active}
            syncing={@status.syncing.active}
          />
        </div>
      </div>
    </.lcars_panel>
    """
  end

  @doc """
  Renders the manual scan section.
  """
  def manual_scan_section(assigns) do
    ~H"""
    <.lcars_panel title="MANUAL SCAN" color="red">
      <.live_component module={ReencodarrWeb.ManualScanComponent} id="manual-scan" />
    </.lcars_panel>
    """
  end

  # Color helper functions
  defp operation_color("blue"), do: "bg-blue-500"
  defp operation_color("purple"), do: "bg-purple-500"
  defp operation_color("green"), do: "bg-green-500"
  defp operation_color("red"), do: "bg-red-500"
  defp operation_color(_), do: "bg-orange-500"

  defp progress_color("blue"), do: "bg-gradient-to-r from-blue-400 to-cyan-500"
  defp progress_color("purple"), do: "bg-gradient-to-r from-purple-400 to-pink-500"
  defp progress_color("green"), do: "bg-gradient-to-r from-green-400 to-emerald-500"
  defp progress_color("red"), do: "bg-gradient-to-r from-red-400 to-orange-500"
  defp progress_color(_), do: "bg-gradient-to-r from-orange-400 to-red-500"

  defp queue_header_color("cyan"), do: "bg-cyan-400"
  defp queue_header_color("green"), do: "bg-green-500"
  defp queue_header_color("purple"), do: "bg-purple-500"
  defp queue_header_color(_), do: "bg-orange-500"

  # Progress display logic
  defp should_show_progress?(active, progress, title) do
    active &&
      (get_progress_percent(progress) > 0 ||
         has_valid_filename?(progress) ||
         get_progress_throughput(progress) >= 0 ||
         title == "ANALYZER")
  end

  defp get_progress_percent(progress), do: Map.get(progress, :percent, 0)
  defp get_progress_throughput(progress), do: Map.get(progress, :throughput, 0.0)

  defp has_valid_filename?(progress) do
    filename = Map.get(progress, :filename)
    filename && filename != :none
  end
end
