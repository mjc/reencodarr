defmodule ReencodarrWeb.UIHelpers do
  @moduledoc """
  User interface utility functions for web components.

  Provides CSS class helpers, button styling, and other UI utilities
  to maintain consistent styling across LiveViews.
  """

  @doc """
  Generates CSS classes for filter buttons with different states and color schemes.
  """
  def filter_button_classes(is_active, color_scheme \\ :orange) do
    base = "px-3 py-1 text-xs rounded transition-colors"

    state_classes =
      case {is_active, color_scheme} do
        {true, :orange} -> "bg-orange-500 text-black"
        {false, :orange} -> "bg-gray-700 text-orange-400 hover:bg-orange-600"
        {true, :blue} -> "bg-blue-500 text-white"
        {false, :blue} -> "bg-gray-700 text-blue-400 hover:bg-blue-600"
        {true, :red} -> "bg-red-500 text-white"
        {false, :red} -> "bg-gray-700 text-red-400 hover:bg-red-600"
      end

    "#{base} #{state_classes}"
  end

  @doc """
  Generates CSS classes for standard action buttons.
  """
  def action_button_classes do
    "px-2 py-1 bg-gray-700 text-orange-400 text-xs rounded hover:bg-orange-600 transition-colors"
  end

  @doc """
  Generates CSS classes for pagination buttons.
  """
  def pagination_button_classes(is_current) do
    base = "px-2 py-1 text-xs rounded transition-colors"

    if is_current do
      "#{base} bg-orange-500 text-black"
    else
      "#{base} bg-gray-700 text-orange-400 hover:bg-orange-600"
    end
  end

  @doc """
  Generates CSS classes for status badges.
  """
  def status_badge_classes(status) do
    base = "px-2 py-1 text-xs rounded"

    status_classes =
      case status do
        :success -> "bg-green-100 text-green-800"
        :warning -> "bg-yellow-100 text-yellow-800"
        :error -> "bg-red-100 text-red-800"
        :info -> "bg-blue-100 text-blue-800"
        _ -> "bg-gray-100 text-gray-800"
      end

    "#{base} #{status_classes}"
  end

  @doc """
  Generates CSS classes for LCARS-style panels based on color.
  """
  def lcars_panel_classes(color) do
    border_color =
      case color do
        :orange -> "border-orange-500"
        :blue -> "border-blue-500"
        :green -> "border-green-500"
        :red -> "border-red-500"
        :purple -> "border-purple-500"
        :cyan -> "border-cyan-400"
        _ -> "border-orange-500"
      end

    "bg-gray-900 border-2 #{border_color} rounded-lg overflow-hidden"
  end

  @doc """
  Formats count values with K/M suffixes for display.
  """
  def format_display_count(count) when is_integer(count) do
    cond do
      count >= 1_000_000 -> "#{Float.round(count / 1_000_000, 1)}M"
      count >= 1_000 -> "#{Float.round(count / 1_000, 1)}K"
      true -> to_string(count)
    end
  end

  def format_display_count(_), do: "N/A"

  @doc """
  Generates CSS classes for filter tags with different color schemes.
  """
  def filter_tag_classes(color_scheme) do
    "px-2 py-1 rounded #{filter_color_classes(color_scheme)}"
  end

  @doc """
  Generates CSS classes for action buttons with specific color schemes.
  """
  def action_button_classes(color_scheme, opts \\ []) do
    size = Keyword.get(opts, :size, :small)
    with_transition = Keyword.get(opts, :transition, false)

    base = button_size_classes(size)
    color_classes = button_color_classes(color_scheme)
    transition = if with_transition, do: " transition-colors", else: ""

    "#{base} #{color_classes}#{transition}"
  end

  @doc """
  Generates CSS classes for LCARS navigation links.

  ## Examples

      iex> navigation_link_classes()
      "px-4 py-2 text-sm font-medium text-orange-400 hover:text-orange-300 transition-colors"

      iex> navigation_link_classes(:active)
      "px-4 py-2 text-sm font-medium bg-orange-500 text-black"
  """
  def navigation_link_classes(state \\ :inactive) do
    base = "px-4 py-2 text-sm font-medium"

    case state do
      :active -> "#{base} bg-orange-500 text-black"
      :inactive -> "#{base} text-orange-400 hover:text-orange-300 transition-colors"
    end
  end

  @doc """
  Generates CSS classes for table row hover effects.

  ## Examples

      iex> table_row_hover_classes()
      "hover:bg-gray-800 transition-colors duration-200"
  """
  def table_row_hover_classes do
    "hover:bg-gray-800 transition-colors duration-200"
  end

  # Private helper functions to reduce complexity

  defp filter_color_classes(:orange), do: "bg-orange-700"
  defp filter_color_classes(:blue), do: "bg-blue-700"
  defp filter_color_classes(:green), do: "bg-green-700"
  defp filter_color_classes(:red), do: "bg-red-700 hover:bg-red-600 transition-colors"
  defp filter_color_classes(:gray), do: "bg-gray-700"
  defp filter_color_classes(:dark_blue), do: "bg-blue-900"
  defp filter_color_classes(:dark_green), do: "bg-green-900"
  defp filter_color_classes(:dark_red), do: "bg-red-900"
  defp filter_color_classes(_), do: "bg-gray-700"

  defp button_size_classes(size) do
    case size do
      :small -> "px-2 py-1 text-xs rounded"
      :medium -> "px-3 py-2 text-sm rounded"
      :large -> "px-4 py-2 text-base rounded"
    end
  end

  defp button_color_classes(color_scheme) do
    case color_scheme do
      :blue -> "bg-blue-600 text-white hover:bg-blue-700"
      :gray -> "bg-gray-600 text-white hover:bg-gray-700"
      :red -> "bg-red-600 text-white hover:bg-red-700"
      :green -> "bg-green-600 text-white hover:bg-green-700"
      :orange -> "bg-orange-600 text-white hover:bg-orange-700"
      _ -> "bg-gray-700 text-orange-400 hover:bg-orange-600"
    end
  end

  @doc """
  Dashboard operation color helpers for consistent theming.
  """
  def operation_color("blue"), do: "bg-blue-500"
  def operation_color("purple"), do: "bg-purple-500"
  def operation_color("green"), do: "bg-green-500"
  def operation_color("red"), do: "bg-red-500"
  def operation_color(_), do: "bg-orange-500"

  def progress_color("blue"), do: "bg-gradient-to-r from-blue-400 to-cyan-500"
  def progress_color("purple"), do: "bg-gradient-to-r from-purple-400 to-pink-500"
  def progress_color("green"), do: "bg-gradient-to-r from-green-400 to-emerald-500"
  def progress_color("red"), do: "bg-gradient-to-r from-red-400 to-orange-500"
  def progress_color(_), do: "bg-gradient-to-r from-orange-400 to-red-500"

  def queue_header_color("cyan"), do: "bg-cyan-400"
  def queue_header_color("green"), do: "bg-green-500"
  def queue_header_color("purple"), do: "bg-purple-500"
  def queue_header_color(_), do: "bg-orange-500"

  @doc """
  Dashboard layout utility classes for common UI patterns.
  """

  # Grid layouts
  def metrics_grid_classes, do: "grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4"

  def operations_grid_classes,
    do: "p-3 sm:p-4 grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4 flex-1 overflow-hidden"

  def queues_grid_classes, do: "grid grid-cols-1 xl:grid-cols-3 gap-4 lg:gap-6"
  def stats_grid_classes, do: "grid grid-cols-2 gap-2 text-xs"

  # Panel layouts
  def operations_panel_classes,
    do:
      "bg-gray-900 border-2 border-yellow-400 rounded-lg overflow-hidden h-64 sm:h-72 flex flex-col"

  def panel_header_classes,
    do: "h-10 sm:h-12 bg-yellow-400 flex items-center px-3 sm:px-4 flex-shrink-0"

  def panel_title_classes, do: "text-black font-bold tracking-wider text-sm sm:text-base"

  def queue_panel_classes,
    do:
      "bg-gray-900 border-2 border-cyan-400 rounded-lg overflow-hidden min-h-[400px] flex flex-col"

  def queue_header_classes, do: "h-8 sm:h-10 flex items-center px-2 sm:px-3"

  def queue_title_classes,
    do: "text-black font-bold tracking-wider text-xs sm:text-sm truncate flex-1"

  # Status and progress
  def status_indicator_classes, do: "flex items-center space-x-2"
  def progress_bar_classes, do: "h-1.5 sm:h-2 bg-gray-800 rounded-full overflow-hidden"
  def progress_bar_fill_classes, do: "h-full transition-all duration-500"

  # File items
  def file_item_classes,
    do:
      "flex items-center space-x-2 sm:space-x-3 p-2 sm:p-3 bg-gray-800 rounded border-l-2 sm:border-l-4 border-orange-500 transition-colors duration-200 hover:bg-gray-700"

  def file_index_badge_classes,
    do:
      "w-6 h-6 sm:w-8 sm:h-8 bg-orange-500 rounded-full flex items-center justify-center flex-shrink-0 shadow-lg"

  def file_name_classes,
    do:
      "text-orange-300 text-xs sm:text-sm tracking-wide truncate font-mono hover:text-orange-200 transition-colors"

  # Common spacing and text
  def section_spacing_classes, do: "space-y-2"
  def section_heading_classes, do: "text-orange-300 text-xs sm:text-sm font-bold tracking-wide"
  def small_text_classes, do: "text-xs text-orange-300 tracking-wide"
  def progress_stats_classes, do: "flex justify-between text-xs text-orange-300"
  def eta_text_classes, do: "text-xs text-orange-400 text-center"
  def crf_vmaf_classes, do: "flex justify-between text-xs text-orange-400"

  @doc """
  Dashboard configuration data for data-driven rendering.
  """

  def dashboard_operations do
    [
      %{title: "CRF SEARCH", key: :crf_searching, color: "purple"},
      %{title: "ENCODING", key: :encoding, color: "blue"},
      %{title: "ANALYZER", key: :analyzing, color: "green"},
      %{title: "SYNC", key: :syncing, color: "red"}
    ]
  end

  def queue_configs do
    [
      %{
        title: "CRF SEARCH QUEUE",
        queue_key: :crf_search,
        queue_type: :crf_search,
        stream_key: :crf_search_queue,
        color: "cyan",
        aria_label: "CRF search processing queue"
      },
      %{
        title: "ENCODING QUEUE",
        queue_key: :encoding,
        queue_type: :encoding,
        stream_key: :encoding_queue,
        color: "green",
        aria_label: "Video encoding processing queue"
      },
      %{
        title: "ANALYZER QUEUE",
        queue_key: :analyzer,
        queue_type: :analyzer,
        stream_key: :analyzer_queue,
        color: "purple",
        aria_label: "Video analysis processing queue"
      }
    ]
  end

  def stats_config do
    [
      %{
        label: "TOTAL VMAFS",
        key: :total_vmafs,
        formatter: &Reencodarr.Formatters.count/1
      },
      %{
        label: "CHOSEN VMAFS",
        key: :chosen_vmafs_count,
        formatter: &Reencodarr.Formatters.count/1
      },
      %{label: "LAST UPDATE", key: :last_video_update, small: true},
      %{label: "LAST INSERT", key: :last_video_insert, small: true}
    ]
  end

  @doc """
  Dashboard Live CSS utility classes for consistent styling.
  """
  def loading_container_classes, do: "text-center text-lcars-orange-300 py-8"
  def dashboard_content_classes, do: "space-y-4 sm:space-y-6"
  def control_grid_classes, do: "grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6"
  def loading_indicator_classes, do: "text-center text-lcars-orange-300 py-4 text-sm"
  def loading_animation_classes, do: "animate-pulse flex items-center justify-center gap-2"
  def bounce_dot_classes, do: "inline-block w-2 h-2 bg-current rounded-full"

  @doc """
  Status indicator CSS classes for dashboard components.
  """
  def status_indicator_classes(:online) do
    %{
      dot: "w-2 h-2 sm:w-3 sm:h-3 rounded-full bg-green-400 animate-pulse",
      text: "text-xs sm:text-sm font-bold tracking-wide text-green-400"
    }
  end

  def status_indicator_classes(:offline) do
    %{
      dot: "w-2 h-2 sm:w-3 sm:h-3 rounded-full bg-gray-600",
      text: "text-xs sm:text-sm font-bold tracking-wide text-gray-500"
    }
  end

  @doc """
  Metadata container classes for different queue types.
  """
  def metadata_container_classes(:crf_search),
    do: "flex flex-wrap gap-2 text-cyan-300 bg-cyan-900/20 rounded px-2 py-1"

  def metadata_container_classes(:encoding),
    do: "flex flex-wrap gap-2 text-green-300 bg-green-900/20 rounded px-2 py-1"

  def metadata_container_classes(:analyzer),
    do: "flex flex-wrap gap-2 text-purple-300 bg-purple-900/20 rounded px-2 py-1"

  @doc """
  Additional UI utility classes for dashboard components.
  """

  # Operation status classes
  def operation_title_classes, do: "h-6 sm:h-8 rounded-r-full flex items-center px-2 sm:px-3"
  def operation_status_spacing_classes, do: "space-y-2 sm:space-y-3"
  def operation_content_spacing_classes, do: "space-y-1 sm:space-y-2"

  # File estimation classes
  def file_estimation_classes, do: "text-xs text-orange-400 flex items-center gap-1"

  def estimation_dot_classes,
    do: "inline-block w-1.5 h-1.5 bg-orange-400 rounded-full animate-pulse"

  # File details classes
  def file_details_classes, do: "flex-1 min-w-0 space-y-1"
  def file_metadata_classes, do: "text-xs mt-1"

  # Progress display classes
  def progress_filename_classes, do: "text-xs text-orange-300 tracking-wide truncate"
  def progress_display_spacing_classes, do: "space-y-1"

  # Analyzer progress classes
  def analyzer_stats_classes, do: "text-xs text-orange-300 space-y-1"
  def analyzer_rate_classes, do: "flex justify-between"
  def analyzer_throughput_classes, do: "text-center"

  # Queue overflow classes
  def queue_overflow_classes, do: "text-center py-1 sm:py-2"
  def queue_overflow_text_classes, do: "text-xs text-orange-300 tracking-wide"

  # Queue content classes
  def queue_items_container_classes, do: "space-y-2 flex-1 overflow-y-auto min-h-0 pr-1"
  def empty_queue_classes, do: "text-center py-4 sm:py-6"
  def empty_queue_icon_classes, do: "text-3xl sm:text-4xl mb-2"
  def empty_queue_text_classes, do: "text-orange-300 tracking-wide text-xs sm:text-sm"

  # Badge and index classes
  def badge_text_classes, do: "text-black font-bold text-xs sm:text-sm"

  # Additional file display utilities
  def estimation_indicator_classes,
    do: "inline-block w-1.5 h-1.5 bg-orange-400 rounded-full animate-pulse"

  def file_name_display_classes, do: "flex items-center space-x-2"
  def filename_text_classes, do: "font-medium text-gray-900 dark:text-gray-100 truncate"
  def path_change_indicator_classes, do: "text-xs text-gray-500 dark:text-gray-400"

  # Queue structure utilities
  def queue_count_container_classes, do: "ml-2"
  def queue_count_text_classes, do: "text-black font-bold text-xs sm:text-sm"
  def queue_content_padding_classes, do: "p-2 sm:p-3 flex-1 min-h-0 flex flex-col"

  # Metadata display utilities
  def metadata_item_classes, do: "flex items-center gap-1 text-xs whitespace-nowrap"
  def metadata_label_classes, do: "font-medium opacity-75"
  def metadata_value_classes, do: "font-mono font-semibold"

  # Control panel utilities
  def control_panel_content_classes, do: "space-y-4"
  def operations_section_classes, do: "space-y-2"
  def operations_heading_classes, do: "text-orange-300 text-xs sm:text-sm font-bold tracking-wide"

  # Status indicator utilities
  def status_indicator_container_classes, do: "flex items-center space-x-2"

  # Dashboard grid layout classes
  def dashboard_section_spacing_classes, do: "space-y-4 sm:space-y-6"
  def dashboard_bottom_grid_classes, do: "grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6"
end
