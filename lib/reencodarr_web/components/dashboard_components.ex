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
  import ReencodarrWeb.UIHelpers
  alias Reencodarr.Formatters

  @doc """
  Renders a responsive grid of metric cards.

  ## Attributes

    * `metrics` (required) - List of metric maps with title, value, and color
  """
  attr :metrics, :list, required: true, doc: "List of metr"

  def metrics_grid(assigns) do
    ~H"""
    <div
      class={metrics_grid_classes()}
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
    assigns = assign(assigns, :operations, dashboard_operations())

    ~H"""
    <section
      class={operations_panel_classes()}
      role="region"
      aria-label="System operations status"
    >
      <header class={panel_header_classes()}>
        <h2 class={panel_title_classes()}>
          SYSTEM OPERATIONS
        </h2>
      </header>

      <div class={operations_grid_classes()}>
        <.operation_status
          :for={op <- @operations}
          title={op.title}
          active={@status[op.key].active}
          progress={@status[op.key].progress}
          color={op.color}
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
    <div class={operation_status_spacing_classes()}>
      <div class={[operation_title_classes(), operation_color(@color)]}>
        <span class={badge_text_classes()}>{@title}</span>
      </div>

      <div class={operation_content_spacing_classes()}>
        <.status_indicator active={@active} />
        <.operation_progress title={@title} active={@active} progress={@progress} color={@color} />
      </div>
    </div>
    """
  end

  # Status indicator component with clear boolean pattern matching
  attr :active, :boolean, required: true

  defp status_indicator(%{active: true} = assigns) do
    classes = status_indicator_classes(:online)
    assigns = assign(assigns, :classes, classes)

    ~H"""
    <div class={status_indicator_container_classes()}>
      <div class={@classes.dot}></div>
      <span class={@classes.text}>ONLINE</span>
    </div>
    """
  end

  defp status_indicator(assigns) do
    classes = status_indicator_classes(:offline)
    assigns = assign(assigns, :classes, classes)

    ~H"""
    <div class={status_indicator_container_classes()}>
      <div class={@classes.dot}></div>
      <span class={@classes.text}>STANDBY</span>
    </div>
    """
  end

  defp operation_progress(%{title: "ANALYZER"} = assigns) do
    ~H"""
    <div class={progress_display_spacing_classes()}>
      <div class={analyzer_stats_classes()}>
        <div class={analyzer_rate_classes()}>
          <span>Rate Limit: {@progress[:rate_limit] || 0}</span>
          <span>Batch Size: {@progress[:batch_size] || 0}</span>
        </div>
        <div class={analyzer_throughput_classes()}>
          <span>{:erlang.float_to_binary(@progress[:throughput] || 0.0, decimals: 2)} files/s</span>
        </div>
      </div>
    </div>
    """
  end

  defp operation_progress(assigns) do
    ~H"""
    <.progress_display :if={show_progress?(@progress)} progress={@progress} color={@color} />
    """
  end

  # Progress display components with proper attribute validation
  attr :progress, :map, required: true
  attr :color, :string, required: true

  defp progress_display(assigns) do
    ~H"""
    <div class={progress_display_spacing_classes()}>
      <.progress_filename :if={@progress.filename} filename={@progress.filename} />
      <.progress_bar progress={@progress} color={@color} />
      <.progress_stats progress={@progress} />
      <.progress_eta :if={@progress[:eta] && @progress.eta != 0} eta={@progress.eta} />
      <.progress_crf_vmaf :if={@progress[:crf] && @progress[:score]} progress={@progress} />
    </div>
    """
  end

  attr :filename, :string, required: true

  defp progress_filename(assigns) do
    ~H"""
    <div class={progress_filename_classes()}>
      {String.upcase(to_string(@filename))}
    </div>
    """
  end

  attr :progress, :map, required: true
  attr :color, :string, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div class={progress_bar_classes()}>
      <div
        class={[progress_bar_fill_classes(), progress_color(@color)]}
        style={"width: #{@progress[:percent] || 0}%"}
      >
      </div>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp progress_stats(assigns) do
    ~H"""
    <div class={progress_stats_classes()}>
      <span>{@progress[:percent] || 0}%</span>
      <.progress_throughput progress={@progress} />
    </div>
    """
  end

  defp progress_throughput(%{progress: %{throughput: throughput}} = assigns)
       when throughput > 0 do
    ~H"""
    <span>{:erlang.float_to_binary(@progress.throughput, decimals: 2)} files/s</span>
    """
  end

  defp progress_throughput(%{progress: %{fps: fps}} = assigns) when fps > 0 do
    ~H"""
    <span>{Formatters.fps(@progress.fps)} FPS</span>
    """
  end

  defp progress_throughput(assigns) do
    ~H"""
    <span></span>
    """
  end

  attr :eta, :integer, required: true

  defp progress_eta(assigns) do
    ~H"""
    <div class={eta_text_classes()}>
      ETA: {Formatters.eta(@eta)}
    </div>
    """
  end

  attr :progress, :map, required: true

  defp progress_crf_vmaf(assigns) do
    ~H"""
    <div class={crf_vmaf_classes()}>
      <span>CRF: {Formatters.crf(@progress.crf)}</span>
      <span>VMAF: {Formatters.vmaf_score(@progress.score)}</span>
    </div>
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
    assigns = assign(assigns, :queue_configs, queue_configs())

    ~H"""
    <section
      class={queues_grid_classes()}
      role="region"
      aria-label="Processing queues"
    >
      <.queue_panel
        :for={config <- @queue_configs}
        title={config.title}
        queue={@queues[config.queue_key]}
        queue_stream={@streams[config.stream_key]}
        color={config.color}
        aria_label={config.aria_label}
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
      class={queue_panel_classes()}
      role="region"
      aria-label={@aria_label || @title}
    >
      <header class={[queue_header_classes(), queue_header_color(@color)]}>
        <h3 class={queue_title_classes()}>
          {@title}
        </h3>
        <div class={queue_count_container_classes()} role="status" aria-label="Queue item count">
          <span class={queue_count_text_classes()}>
            {Formatters.count(@queue.total_count)}
          </span>
        </div>
      </header>

      <div class={queue_content_padding_classes()}>
        <.queue_content queue={@queue} queue_stream={@queue_stream} color={@color} />
      </div>
    </article>
    """
  end

  defp queue_content(%{queue: %{total_count: 0}} = assigns) do
    ~H"""
    <div class={empty_queue_classes()} role="status">
      <div class={empty_queue_icon_classes()} aria-hidden="true">🎉</div>
      <p class={empty_queue_text_classes()}>QUEUE EMPTY</p>
    </div>
    """
  end

  defp queue_content(assigns) do
    ~H"""
    <div
      class={queue_items_container_classes()}
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
    <div class={queue_overflow_classes()} role="status">
      <span class={queue_overflow_text_classes()}>
        SHOWING FIRST 10 OF {Formatters.count(@total_count)} ITEMS
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
      class={file_item_classes()}
      role="listitem"
      id={@id}
    >
      <.file_index_badge index={@file.index} />
      <.file_details file={@file} queue={@queue} />
    </div>
    """
  end

  attr :index, :integer, required: true

  defp file_index_badge(assigns) do
    ~H"""
    <div
      class={file_index_badge_classes()}
      role="img"
      aria-label={"File position #{@index}"}
    >
      <span class={badge_text_classes()}>{@index}</span>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :queue, :map, required: true

  defp file_details(assigns) do
    ~H"""
    <div class={file_details_classes()}>
      <.file_name_display file={@file} />
      <.file_estimation file={@file} />
      <.queue_metadata file={@file} queue={@queue} />
    </div>
    """
  end

  attr :file, :map, required: true

  defp file_name_display(assigns) do
    ~H"""
    <p
      class={file_name_classes()}
      title={@file.display_name}
    >
      {String.upcase(@file.display_name)}
    </p>
    """
  end

  defp file_estimation(%{file: %{estimated_percent: percent}} = assigns)
       when not is_nil(percent) do
    ~H"""
    <p
      class={file_estimation_classes()}
      role="status"
      aria-label="Estimated progress"
    >
      <span class={estimation_indicator_classes()}></span> EST: ~{@file.estimated_percent}%
    </p>
    """
  end

  defp file_estimation(assigns), do: ~H""

  attr :file, :map, required: true
  attr :queue, :map, required: true

  defp queue_metadata(assigns) do
    # Map queue titles to types - more reliable than searching configs
    queue_type =
      case assigns.queue.title do
        "CRF Search Queue" -> :crf_search
        "Encoding Queue" -> :encoding
        "Analyzer Queue" -> :analyzer
        _ -> :unknown
      end

    assigns = assign(assigns, :queue_type, queue_type)

    ~H"""
    <div class={file_metadata_classes()} role="group" aria-label="File metadata">
      <.metadata_display file={@file} queue_type={@queue_type} />
    </div>
    """
  end

  # Single unified metadata display with pattern matching
  defp metadata_display(%{queue_type: :crf_search} = assigns) do
    ~H"""
    <div class={metadata_container_classes(:crf_search)}>
      <.metadata_item
        :if={@file.bitrate}
        icon="📶"
        label="Bitrate"
        value={Formatters.bitrate_mbps(@file.bitrate)}
      />
      <.metadata_item
        :if={@file.size}
        icon="💾"
        label="Size"
        value={Formatters.file_size(@file.size)}
      />
    </div>
    """
  end

  defp metadata_display(%{queue_type: :encoding} = assigns) do
    ~H"""
    <div class={metadata_container_classes(:encoding)}>
      <.metadata_item
        :if={@file.estimated_savings_bytes}
        icon="💰"
        label="Savings"
        value={Formatters.savings_bytes(@file.estimated_savings_bytes)}
      />
      <.metadata_item
        :if={@file.size}
        icon="💾"
        label="Size"
        value={Formatters.file_size(@file.size)}
      />
    </div>
    """
  end

  defp metadata_display(%{queue_type: :analyzer} = assigns) do
    ~H"""
    <div class={metadata_container_classes(:analyzer)}>
      <.metadata_item
        :if={@file.duration}
        icon="⏱️"
        label="Duration"
        value={Formatters.duration(@file.duration)}
      />
      <.metadata_item
        :if={@file.codec}
        icon="🎥"
        label="Codec"
        value={@file.codec}
      />
    </div>
    """
  end

  defp metadata_display(assigns), do: ~H""

  # Reusable metadata item component
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp metadata_item(assigns) do
    ~H"""
    <span class={metadata_item_classes()} title={"#{@label}: #{@value}"}>
      <span aria-hidden="true">{@icon}</span>
      <span class={metadata_label_classes()}>{@label}:</span>
      <span class={metadata_value_classes()}>{@value}</span>
    </span>
    """
  end

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
      <div class={control_panel_content_classes()} role="region" aria-label="System control panel">
        <.statistics_section stats={@stats} />
        <.operations_section status={@status} />
      </div>
    </.lcars_panel>
    """
  end

  attr :stats, :map, required: true

  defp statistics_section(assigns) do
    assigns = assign(assigns, :stats_config, build_stats_config(assigns.stats))

    ~H"""
    <section class={section_spacing_classes()} aria-labelledby="stats-heading">
      <h3 id="stats-heading" class={section_heading_classes()}>
        STATISTICS
      </h3>
      <div class={stats_grid_classes()}>
        <.lcars_stat_row
          :for={stat <- @stats_config}
          label={stat.label}
          value={stat.value}
          small={Map.get(stat, :small, false)}
        />
      </div>
    </section>
    """
  end

  # Helper function to build statistics configuration
  defp build_stats_config(stats) do
    Enum.map(stats_config(), fn config ->
      value = Map.get(stats, config.key)

      formatted_value =
        if formatter = Map.get(config, :formatter) do
          formatter.(value)
        else
          value
        end

      config
      |> Map.put(:value, formatted_value)
      |> Map.drop([:key, :formatter])
    end)
  end

  attr :status, :map, required: true

  defp operations_section(assigns) do
    ~H"""
    <section class={operations_section_classes()} aria-labelledby="operations-heading">
      <h3 id="operations-heading" class={operations_heading_classes()}>
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

  # Progress display logic - idiomatic pattern matching
  defp show_progress?(%{percent: percent}) when percent > 0, do: true
  defp show_progress?(%{filename: filename}) when is_binary(filename) and filename != "", do: true
  defp show_progress?(%{throughput: throughput}) when throughput > 0, do: true
  defp show_progress?(_), do: false
end
