defmodule ReencodarrWeb.DashboardComponents do
  @moduledoc """
  Modern dashboard components for Reencodarr overview.

  Provides optimized, reusable components with:
  - Proper attribute documentation
  - Slots for extensibility
  - Modern HEEx patterns
  - LCARS-themed styling
  """

  use Phoenix.Component
  import ReencodarrWeb.LcarsComponents
  alias Reencodarr.Formatters

  @doc """
  Renders a responsive grid of metric cards.

  ## Attributes

    * `metrics` (required) - List of metric maps with title, value, and color
  """
  attr :metrics, :list, required: true, doc: "List of metric data to display"

  def metrics_grid(assigns) do
    ~H"""
    <div
      class="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4"
      role="region"
      aria-label="System metrics"
    >
      <.lcars_metric_card
        :for={metric <- @metrics}
        metric={metric}
      />
    </div>
    """
  end

  @doc """
  Renders the system operations status panel.

  Shows real-time status of all system operations including
  CRF search, encoding, analysis, and synchronization.

  ## Attributes

    * `status` (required) - Map containing operation status data
  """
  attr :status, :map, required: true, doc: "System operations status data"

  def operations_panel(assigns) do
    ~H"""
    <section
      class="bg-gray-900 border-2 border-yellow-400 rounded-lg overflow-hidden h-64 sm:h-72 flex flex-col"
      role="region"
      aria-label="System operations status"
    >
      <header class="h-10 sm:h-12 bg-yellow-400 flex items-center px-3 sm:px-4 flex-shrink-0">
        <h2 class="text-black font-bold tracking-wider text-sm sm:text-base">
          SYSTEM OPERATIONS
        </h2>
      </header>

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
    </section>
    """
  end

  # Individual operation status indicator.
  #
  # ## Attributes
  #
  #   * `title` (required) - Operation name
  #   * `active` (required) - Whether operation is currently active
  #   * `progress` (required) - Progress data map
  #   * `color` (required) - Color theme: purple, blue, green, or red
  attr :title, :string, required: true
  attr :active, :boolean, required: true
  attr :progress, :map, required: true
  attr :color, :string, required: true, values: ~w(purple blue green red)

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
  Renders the processing queues section with live streaming updates.

  Displays three main queues in a responsive grid:
  - CRF Search Queue
  - Encoding Queue
  - Analyzer Queue

  ## Attributes

    * `queues` (required) - Map containing queue data for each operation
    * `streams` (required) - Map of LiveView streams for real-time updates
  """
  attr :queues, :map, required: true, doc: "Queue data for all operations"
  attr :streams, :map, required: true, doc: "LiveView streams for real-time queue updates"

  def queues_section(assigns) do
    ~H"""
    <section
      class="grid grid-cols-1 lg:grid-cols-3 gap-3 sm:gap-4"
      role="region"
      aria-label="Processing queues"
    >
      <.queue_panel
        title="CRF SEARCH QUEUE"
        queue={@queues.crf_search}
        queue_stream={@streams.crf_search_queue}
        color="cyan"
        aria_label="CRF search processing queue"
      />
      <.queue_panel
        title="ENCODING QUEUE"
        queue={@queues.encoding}
        queue_stream={@streams.encoding_queue}
        color="green"
        aria_label="Video encoding processing queue"
      />
      <.queue_panel
        title="ANALYZER QUEUE"
        queue={@queues.analyzer}
        queue_stream={@streams.analyzer_queue}
        color="purple"
        aria_label="Video analysis processing queue"
      />
    </section>
    """
  end

  # Individual queue panel with real-time updates.
  #
  # ## Attributes
  #
  #   * `title` (required) - Queue display title
  #   * `queue` (required) - Queue data including count and items
  #   * `queue_stream` (required) - LiveView stream for this queue
  #   * `color` (required) - Theme color: cyan, green, or purple
  #   * `aria_label` - Accessibility label for screen readers
  attr :title, :string, required: true
  attr :queue, :map, required: true
  attr :queue_stream, :any, required: true
  attr :color, :string, required: true, values: ~w(cyan green purple)
  attr :aria_label, :string, default: nil

  defp queue_panel(assigns) do
    ~H"""
    <article
      class="bg-gray-900 border-2 border-cyan-400 rounded-lg overflow-hidden"
      role="region"
      aria-label={@aria_label || @title}
    >
      <header class={[
        "h-8 sm:h-10 flex items-center px-2 sm:px-3",
        queue_header_color(@color)
      ]}>
        <h3 class="text-black font-bold tracking-wider text-xs sm:text-sm truncate flex-1">
          {@title}
        </h3>
        <div class="ml-2" role="status" aria-label="Queue item count">
          <span class="text-black font-bold text-xs sm:text-sm">
            {Formatters.format_count(@queue.total_count)}
          </span>
        </div>
      </header>

      <div class="p-2 sm:p-3">
        <.queue_content queue={@queue} queue_stream={@queue_stream} color={@color} />
      </div>
    </article>
    """
  end

  defp queue_content(%{queue: %{total_count: 0}} = assigns) do
    ~H"""
    <div class="text-center py-4 sm:py-6" role="status">
      <div class="text-3xl sm:text-4xl mb-2" aria-hidden="true">🎉</div>
      <p class="text-orange-300 tracking-wide text-xs sm:text-sm">QUEUE EMPTY</p>
    </div>
    """
  end

  defp queue_content(assigns) do
    ~H"""
    <div
      class="space-y-1 sm:space-y-2 max-h-48 sm:max-h-64 overflow-y-auto"
      id={"#{@color}-queue-container"}
      role="list"
      aria-label="Queue items"
    >
      <div phx-update="stream" id={"#{@color}-queue-items"}>
        <.queue_file_item
          :for={{item_id, file} <- @queue_stream || []}
          id={item_id}
          file={file}
          queue={@queue}
        />
      </div>

      <.queue_overflow_indicator
        :if={@queue.total_count > 10}
        total_count={@queue.total_count}
      />
    </div>
    """
  end

  defp queue_overflow_indicator(assigns) do
    ~H"""
    <div class="text-center py-1 sm:py-2" role="status">
      <span class="text-xs text-orange-300 tracking-wide">
        SHOWING FIRST 10 OF {Formatters.format_count(@total_count)} ITEMS
      </span>
    </div>
    """
  end

  # Individual file item within a queue with modern patterns.
  #
  # ## Attributes
  #
  #   * `id` - DOM ID for the item (for stream updates)
  #   * `file` (required) - File data including name, progress, metadata
  #   * `queue` (required) - Queue context for type-specific display
  attr :id, :string, default: nil
  attr :file, :map, required: true
  attr :queue, :map, required: true

  defp queue_file_item(assigns) do
    ~H"""
    <div
      class="flex items-center space-x-2 sm:space-x-3 p-2 sm:p-3 bg-gray-800 rounded border-l-2 sm:border-l-4 border-orange-500 transition-colors duration-200 hover:bg-gray-700"
      role="listitem"
      id={@id}
    >
      <.file_index_badge index={@file.index} />
      <.file_details file={@file} queue={@queue} />
    </div>
    """
  end

  defp file_index_badge(assigns) do
    ~H"""
    <div
      class="w-6 h-6 sm:w-8 sm:h-8 bg-orange-500 rounded-full flex items-center justify-center flex-shrink-0 shadow-lg"
      role="img"
      aria-label={"File position #{@index}"}
    >
      <span class="text-black font-bold text-xs sm:text-sm">{@index}</span>
    </div>
    """
  end

  defp file_details(assigns) do
    ~H"""
    <div class="flex-1 min-w-0 space-y-1">
      <.file_name_display file={@file} />
      <.file_estimation :if={@file.estimated_percent} percent={@file.estimated_percent} />
      <.queue_metadata file={@file} queue={@queue} />
    </div>
    """
  end

  defp file_name_display(assigns) do
    ~H"""
    <p
      class="text-orange-300 text-xs sm:text-sm tracking-wide truncate font-mono hover:text-orange-200 transition-colors"
      title={@file.display_name}
    >
      {String.upcase(@file.display_name)}
    </p>
    """
  end

  defp file_estimation(assigns) do
    ~H"""
    <p
      class="text-xs text-orange-400 flex items-center gap-1"
      role="status"
      aria-label="Estimated progress"
    >
      <span class="inline-block w-1.5 h-1.5 bg-orange-400 rounded-full animate-pulse"></span>
      EST: ~{@percent}%
    </p>
    """
  end

  defp queue_metadata(assigns) do
    ~H"""
    <div class="text-xs mt-1" role="group" aria-label="File metadata">
      <.crf_search_metadata :if={crf_search_queue?(@queue)} file={@file} />
      <.encoding_metadata :if={encoding_queue?(@queue)} file={@file} />
      <.analyzer_metadata :if={analyzer_queue?(@queue)} file={@file} />
    </div>
    """
  end

  # Modern queue-specific metadata components with better conditional rendering

  defp crf_search_metadata(%{file: file} = assigns)
       when not is_nil(file.bitrate) or not is_nil(file.size) do
    ~H"""
    <div class="flex justify-between items-center text-cyan-300 bg-cyan-900/20 rounded px-2 py-1">
      <.metadata_item
        :if={@file.bitrate}
        icon="📶"
        label="Bitrate"
        value={Formatters.format_bitrate_mbps(@file.bitrate)}
      />
      <.metadata_item
        :if={@file.size}
        icon="💾"
        label="Size"
        value={Formatters.format_file_size(@file.size)}
      />
    </div>
    """
  end

  defp crf_search_metadata(assigns), do: ~H""

  defp encoding_metadata(%{file: file} = assigns)
       when not is_nil(file.estimated_savings_bytes) or not is_nil(file.size) do
    ~H"""
    <div class="flex justify-between items-center text-green-300 bg-green-900/20 rounded px-2 py-1">
      <.metadata_item
        :if={@file.estimated_savings_bytes}
        icon="💰"
        label="Savings"
        value={Formatters.format_savings_bytes(@file.estimated_savings_bytes)}
      />
      <.metadata_item
        :if={@file.size}
        icon="💾"
        label="Size"
        value={Formatters.format_file_size(@file.size)}
      />
    </div>
    """
  end

  defp encoding_metadata(assigns), do: ~H""

  defp analyzer_metadata(%{file: file} = assigns)
       when not is_nil(file.duration) or not is_nil(file.codec) do
    ~H"""
    <div class="flex justify-between items-center text-purple-300 bg-purple-900/20 rounded px-2 py-1">
      <.metadata_item :if={@file.duration} icon="⏱️" label="Duration" value={@file.duration} />
      <.metadata_item :if={@file.codec} icon="🎥" label="Codec" value={@file.codec} />
    </div>
    """
  end

  defp analyzer_metadata(assigns), do: ~H""

  # Reusable metadata item component
  defp metadata_item(assigns) do
    ~H"""
    <span class="flex items-center gap-1 text-xs" title={"#{@label}: #{@value}"}>
      <span aria-hidden="true">{@icon}</span>
      <span class="font-medium">{@label}:</span>
      <span class="font-mono">{@value}</span>
    </span>
    """
  end

  # Helper functions for queue type detection with better pattern matching
  defp crf_search_queue?(%{title: "CRF Search Queue"}), do: true
  defp crf_search_queue?(_), do: false

  defp encoding_queue?(%{title: "Encoding Queue"}), do: true
  defp encoding_queue?(_), do: false

  defp analyzer_queue?(%{title: "Analyzer Queue"}), do: true
  defp analyzer_queue?(_), do: false

  @doc """
  Renders the control panel with statistics and operations controls.

  Displays system statistics and interactive operation controls in
  a modern LCARS-styled panel.

  ## Attributes

    * `status` (required) - System operation status data
    * `stats` (required) - Statistical information to display
  """
  attr :status, :map, required: true, doc: "Current system operation status"
  attr :stats, :map, required: true, doc: "System statistics data"

  def control_panel(assigns) do
    ~H"""
    <.lcars_panel title="CONTROL PANEL" color="green">
      <div class="space-y-4" role="region" aria-label="System control panel">
        <.statistics_section stats={@stats} />
        <.operations_section status={@status} />
      </div>
    </.lcars_panel>
    """
  end

  defp statistics_section(assigns) do
    ~H"""
    <section class="space-y-2" aria-labelledby="stats-heading">
      <h3 id="stats-heading" class="text-orange-300 text-xs sm:text-sm font-bold tracking-wide">
        STATISTICS
      </h3>
      <div class="grid grid-cols-2 gap-2 text-xs">
        <.lcars_stat_row
          label="TOTAL VMAFS"
          value={Formatters.format_count(@stats.total_vmafs)}
        />
        <.lcars_stat_row
          label="CHOSEN VMAFS"
          value={Formatters.format_count(@stats.chosen_vmafs_count)}
        />
        <.lcars_stat_row
          label="LAST UPDATE"
          value={@stats.last_video_update}
          small={true}
        />
        <.lcars_stat_row
          label="LAST INSERT"
          value={@stats.last_video_insert}
          small={true}
        />
      </div>
    </section>
    """
  end

  defp operations_section(assigns) do
    ~H"""
    <section class="space-y-2" aria-labelledby="operations-heading">
      <h3 id="operations-heading" class="text-orange-300 text-xs sm:text-sm font-bold tracking-wide">
        OPERATIONS
      </h3>
      <.live_component
        module={ReencodarrWeb.ControlButtonsComponent}
        id="control-buttons"
        encoding={@status.encoding.active}
        crf_searching={@status.crf_searching.active}
        analyzing={@status.analyzing.active}
        syncing={@status.syncing.active}
      />
    </section>
    """
  end

  @doc """
  Renders the manual scan section with enhanced UX.

  Provides an interface for manually triggering file scans
  with improved styling and user feedback.
  """
  def manual_scan_section(assigns) do
    ~H"""
    <.lcars_panel title="MANUAL SCAN" color="red">
      <div role="region" aria-label="Manual file scanning interface">
        <.live_component
          module={ReencodarrWeb.ManualScanComponent}
          id="manual-scan"
        />
      </div>
    </.lcars_panel>
    """
  end

  # Color helper functions - consolidated for better maintainability

  @operation_colors %{
    "blue" => "bg-blue-500",
    "purple" => "bg-purple-500",
    "green" => "bg-green-500",
    "red" => "bg-red-500"
  }

  @progress_colors %{
    "blue" => "bg-gradient-to-r from-blue-400 to-cyan-500",
    "purple" => "bg-gradient-to-r from-purple-400 to-pink-500",
    "green" => "bg-gradient-to-r from-green-400 to-emerald-500",
    "red" => "bg-gradient-to-r from-red-400 to-orange-500"
  }

  @queue_header_colors %{
    "cyan" => "bg-cyan-400",
    "green" => "bg-green-500",
    "purple" => "bg-purple-500"
  }

  defp operation_color(color), do: Map.get(@operation_colors, color, "bg-orange-500")

  defp progress_color(color),
    do: Map.get(@progress_colors, color, "bg-gradient-to-r from-orange-400 to-red-500")

  defp queue_header_color(color), do: Map.get(@queue_header_colors, color, "bg-orange-500")

  # Progress display logic - simplified for better readability
  defp should_show_progress?(active, progress, title) do
    active &&
      (get_progress_percent(progress) > 0 ||
         has_valid_filename?(progress) ||
         get_progress_throughput(progress) > 0 ||
         title == "ANALYZER")
  end

  defp get_progress_percent(progress) when is_map(progress), do: Map.get(progress, :percent, 0)
  defp get_progress_percent(_), do: 0

  defp get_progress_throughput(progress) when is_map(progress),
    do: Map.get(progress, :throughput, 0.0)

  defp get_progress_throughput(_), do: 0.0

  defp has_valid_filename?(progress) when is_map(progress) do
    case Map.get(progress, :filename) do
      nil -> false
      :none -> false
      filename when is_binary(filename) -> String.trim(filename) != ""
      _ -> false
    end
  end

  defp has_valid_filename?(_), do: false
end
