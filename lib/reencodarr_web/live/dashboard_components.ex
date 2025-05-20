defmodule ReencodarrWeb.DashboardComponents do
  use Phoenix.Component

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

  # Summary Row
  def render_summary_row(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.SummaryRowComponent}
      id="summary-row"
      stats={@stats}
    />
    """
  end

  # Manual Scan Form
  def render_manual_scan_form(assigns) do
    ~H"""
    <.live_component module={ReencodarrWeb.ManualScanComponent} id="manual-scan" />
    """
  end

  # Queue Information
  def render_queue_information(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.QueueInformationComponent}
      id="queue-information"
      stats={@stats}
    />
    """
  end

  # Progress Information
  def render_progress_information(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.ProgressInformationComponent}
      id="progress-information"
      sync_progress={@sync_progress}
      encoding_progress={@encoding_progress}
      crf_search_progress={@crf_search_progress}
    />
    """
  end

  # Statistics
  def render_statistics(assigns) do
    ~H"""
    <.live_component
      module={ReencodarrWeb.StatisticsComponent}
      id="statistics"
      stats={@stats}
      timezone={@timezone}
    />
    """
  end
end
