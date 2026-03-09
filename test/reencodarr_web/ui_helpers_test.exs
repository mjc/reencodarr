defmodule ReencodarrWeb.UIHelpersTest do
  use ExUnit.Case, async: true

  alias ReencodarrWeb.UIHelpers

  describe "filter_button_classes/2" do
    test "active orange returns classes with bg-orange-500" do
      result = UIHelpers.filter_button_classes(true, :orange)
      assert String.contains?(result, "bg-orange-500")
    end

    test "inactive orange returns classes with bg-gray-700" do
      result = UIHelpers.filter_button_classes(false, :orange)
      assert String.contains?(result, "bg-gray-700")
    end

    test "active blue returns classes with bg-blue-500" do
      result = UIHelpers.filter_button_classes(true, :blue)
      assert String.contains?(result, "bg-blue-500")
    end

    test "inactive blue returns classes with bg-gray-700" do
      result = UIHelpers.filter_button_classes(false, :blue)
      assert String.contains?(result, "bg-gray-700")
    end

    test "active red returns classes with bg-red-500" do
      result = UIHelpers.filter_button_classes(true, :red)
      assert String.contains?(result, "bg-red-500")
    end

    test "inactive red returns classes with bg-gray-700" do
      result = UIHelpers.filter_button_classes(false, :red)
      assert String.contains?(result, "bg-gray-700")
    end

    test "returns a string" do
      assert is_binary(UIHelpers.filter_button_classes(true, :orange))
    end

    test "defaults color_scheme to orange when called with one arg" do
      active_with_default = UIHelpers.filter_button_classes(true)
      active_with_orange = UIHelpers.filter_button_classes(true, :orange)
      assert active_with_default == active_with_orange
    end
  end

  describe "action_button_classes/0" do
    test "returns a non-empty string" do
      result = UIHelpers.action_button_classes()
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "includes orange color styling" do
      result = UIHelpers.action_button_classes()
      assert String.contains?(result, "orange")
    end
  end

  describe "pagination_button_classes/1" do
    test "current page has bg-orange-500" do
      result = UIHelpers.pagination_button_classes(true)
      assert String.contains?(result, "bg-orange-500")
    end

    test "non-current page has bg-gray-700" do
      result = UIHelpers.pagination_button_classes(false)
      assert String.contains?(result, "bg-gray-700")
    end

    test "returns a string for both values" do
      assert is_binary(UIHelpers.pagination_button_classes(true))
      assert is_binary(UIHelpers.pagination_button_classes(false))
    end
  end

  describe "status_badge_classes/1" do
    test ":success returns green classes" do
      result = UIHelpers.status_badge_classes(:success)
      assert String.contains?(result, "green")
    end

    test ":warning returns yellow classes" do
      result = UIHelpers.status_badge_classes(:warning)
      assert String.contains?(result, "yellow")
    end

    test ":error returns red classes" do
      result = UIHelpers.status_badge_classes(:error)
      assert String.contains?(result, "red")
    end

    test ":info returns blue classes" do
      result = UIHelpers.status_badge_classes(:info)
      assert String.contains?(result, "blue")
    end

    test "unknown status falls back to gray classes" do
      result = UIHelpers.status_badge_classes(:unknown)
      assert String.contains?(result, "gray")
    end
  end

  describe "lcars_panel_classes/1" do
    test "orange border" do
      result = UIHelpers.lcars_panel_classes(:orange)
      assert String.contains?(result, "border-orange-500")
    end

    test "blue border" do
      result = UIHelpers.lcars_panel_classes(:blue)
      assert String.contains?(result, "border-blue-500")
    end

    test "unknown color defaults to orange border" do
      result = UIHelpers.lcars_panel_classes(:unknown)
      assert String.contains?(result, "border-orange-500")
    end

    test "returns a string" do
      assert is_binary(UIHelpers.lcars_panel_classes(:green))
    end
  end

  describe "navigation_link_classes/1" do
    test "active state has bg-orange-500" do
      result = UIHelpers.navigation_link_classes(:active)
      assert String.contains?(result, "bg-orange-500")
    end

    test "inactive state does not have bg-orange-500" do
      result = UIHelpers.navigation_link_classes(:inactive)
      refute String.contains?(result, "bg-orange-500")
    end

    test "defaults to inactive" do
      default_result = UIHelpers.navigation_link_classes()
      inactive_result = UIHelpers.navigation_link_classes(:inactive)
      assert default_result == inactive_result
    end
  end

  describe "table_row_hover_classes/0" do
    test "returns a non-empty string" do
      result = UIHelpers.table_row_hover_classes()
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "includes hover and transition styling" do
      result = UIHelpers.table_row_hover_classes()
      assert String.contains?(result, "hover:")
      assert String.contains?(result, "transition")
    end
  end

  describe "operation_color/1" do
    test "blue returns bg-blue-500" do
      assert UIHelpers.operation_color("blue") == "bg-blue-500"
    end

    test "green returns bg-green-500" do
      assert UIHelpers.operation_color("green") == "bg-green-500"
    end

    test "unknown defaults to bg-orange-500" do
      assert UIHelpers.operation_color("unknown") == "bg-orange-500"
    end
  end

  describe "status_indicator_classes/1 with atom argument" do
    test ":online returns a map with dot and text keys" do
      result = UIHelpers.status_indicator_classes(:online)
      assert is_map(result)
      assert Map.has_key?(result, :dot)
      assert Map.has_key?(result, :text)
    end

    test ":online dot includes green" do
      result = UIHelpers.status_indicator_classes(:online)
      assert String.contains?(result.dot, "green")
    end

    test ":offline returns a map with dot and text keys" do
      result = UIHelpers.status_indicator_classes(:offline)
      assert is_map(result)
    end

    test ":offline dot includes gray" do
      result = UIHelpers.status_indicator_classes(:offline)
      assert String.contains?(result.dot, "gray")
    end
  end

  describe "metadata_container_classes/1" do
    test ":crf_search returns cyan-themed classes" do
      result = UIHelpers.metadata_container_classes(:crf_search)
      assert String.contains?(result, "cyan")
    end

    test ":encoding returns green-themed classes" do
      result = UIHelpers.metadata_container_classes(:encoding)
      assert String.contains?(result, "green")
    end

    test ":analyzer returns purple-themed classes" do
      result = UIHelpers.metadata_container_classes(:analyzer)
      assert String.contains?(result, "purple")
    end
  end

  describe "dashboard_operations/0" do
    test "returns a list" do
      result = UIHelpers.dashboard_operations()
      assert is_list(result)
    end

    test "contains 4 operations" do
      result = UIHelpers.dashboard_operations()
      assert length(result) == 4
    end

    test "each operation has title, key, and color fields" do
      result = UIHelpers.dashboard_operations()

      Enum.each(result, fn op ->
        assert Map.has_key?(op, :title)
        assert Map.has_key?(op, :key)
        assert Map.has_key?(op, :color)
      end)
    end
  end

  describe "queue_configs/0" do
    test "returns a list of 3 configs" do
      result = UIHelpers.queue_configs()
      assert is_list(result)
      assert length(result) == 3
    end

    test "each config has required keys" do
      result = UIHelpers.queue_configs()

      Enum.each(result, fn config ->
        assert Map.has_key?(config, :title)
        assert Map.has_key?(config, :queue_key)
        assert Map.has_key?(config, :color)
      end)
    end
  end

  describe "filter_tag_classes/1" do
    test "orange returns a string containing bg-orange-700" do
      result = UIHelpers.filter_tag_classes(:orange)
      assert String.contains?(result, "bg-orange-700")
    end

    test "blue returns a string containing bg-blue-700" do
      result = UIHelpers.filter_tag_classes(:blue)
      assert String.contains?(result, "bg-blue-700")
    end

    test "unknown color falls back to gray" do
      result = UIHelpers.filter_tag_classes(:unknown)
      assert String.contains?(result, "bg-gray-700")
    end
  end

  describe "action_button_classes/2" do
    test "blue color scheme contains bg-blue-600" do
      result = UIHelpers.action_button_classes(:blue)
      assert String.contains?(result, "bg-blue-600")
    end

    test "red color scheme contains bg-red-600" do
      result = UIHelpers.action_button_classes(:red)
      assert String.contains?(result, "bg-red-600")
    end

    test "medium size contains text-sm" do
      result = UIHelpers.action_button_classes(:blue, size: :medium)
      assert String.contains?(result, "text-sm")
    end

    test "transition option appends transition-colors" do
      result = UIHelpers.action_button_classes(:blue, transition: true)
      assert String.contains?(result, "transition-colors")
    end

    test "without transition option does not have transition-colors" do
      result = UIHelpers.action_button_classes(:blue)
      refute String.contains?(result, "transition-colors")
    end
  end

  describe "format_display_count/1" do
    test "formats integer 0 as string" do
      result = UIHelpers.format_display_count(0)
      assert is_binary(result)
    end

    test "formats a positive integer" do
      result = UIHelpers.format_display_count(42)
      assert String.contains?(result, "42")
    end

    test "returns N/A for nil" do
      assert UIHelpers.format_display_count(nil) == "N/A"
    end
  end

  describe "progress_color/1" do
    test "blue returns cyan gradient" do
      result = UIHelpers.progress_color("blue")
      assert String.contains?(result, "cyan")
    end

    test "green returns emerald gradient" do
      result = UIHelpers.progress_color("green")
      assert String.contains?(result, "emerald")
    end

    test "unknown defaults to orange gradient" do
      result = UIHelpers.progress_color("other")
      assert String.contains?(result, "orange")
    end
  end

  describe "queue_header_color/1" do
    test "cyan returns bg-cyan-400" do
      assert UIHelpers.queue_header_color("cyan") == "bg-cyan-400"
    end

    test "green returns bg-green-500" do
      assert UIHelpers.queue_header_color("green") == "bg-green-500"
    end

    test "unknown defaults to bg-orange-500" do
      assert UIHelpers.queue_header_color("other") == "bg-orange-500"
    end
  end

  # ------------------------------------------------------------------
  # Grid / layout classes
  # ------------------------------------------------------------------

  describe "metrics_grid_classes/0" do
    test "returns grid classes" do
      result = UIHelpers.metrics_grid_classes()
      assert is_binary(result)
      assert String.contains?(result, "grid")
      assert String.contains?(result, "gap")
    end
  end

  describe "operations_grid_classes/0" do
    test "returns grid classes with padding" do
      result = UIHelpers.operations_grid_classes()
      assert is_binary(result)
      assert String.contains?(result, "grid")
      assert String.contains?(result, "overflow-hidden")
    end
  end

  describe "queues_grid_classes/0" do
    test "returns grid classes" do
      result = UIHelpers.queues_grid_classes()
      assert is_binary(result)
      assert String.contains?(result, "grid")
      assert String.contains?(result, "gap")
    end
  end

  describe "stats_grid_classes/0" do
    test "returns grid text-xs classes" do
      result = UIHelpers.stats_grid_classes()
      assert is_binary(result)
      assert String.contains?(result, "grid")
      assert String.contains?(result, "text-xs")
    end
  end

  # ------------------------------------------------------------------
  # Panel classes
  # ------------------------------------------------------------------

  describe "operations_panel_classes/0" do
    test "returns panel classes with border and flex" do
      result = UIHelpers.operations_panel_classes()
      assert is_binary(result)
      assert String.contains?(result, "border")
      assert String.contains?(result, "flex")
    end
  end

  describe "queue_panel_classes/0" do
    test "returns panel classes with cyan border" do
      result = UIHelpers.queue_panel_classes()
      assert is_binary(result)
      assert String.contains?(result, "border-cyan-400")
      assert String.contains?(result, "flex")
    end
  end

  # ------------------------------------------------------------------
  # Header / title classes
  # ------------------------------------------------------------------

  describe "panel_header_classes/0" do
    test "returns header classes with yellow background" do
      result = UIHelpers.panel_header_classes()
      assert is_binary(result)
      assert String.contains?(result, "bg-yellow-400")
      assert String.contains?(result, "flex")
    end
  end

  describe "panel_title_classes/0" do
    test "returns title classes with font-bold" do
      result = UIHelpers.panel_title_classes()
      assert is_binary(result)
      assert String.contains?(result, "font-bold")
      assert String.contains?(result, "text-black")
    end
  end

  describe "queue_header_classes/0" do
    test "returns header classes with flex" do
      result = UIHelpers.queue_header_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "items-center")
    end
  end

  describe "queue_title_classes/0" do
    test "returns title classes with font-bold and truncate" do
      result = UIHelpers.queue_title_classes()
      assert is_binary(result)
      assert String.contains?(result, "font-bold")
      assert String.contains?(result, "truncate")
    end
  end

  # ------------------------------------------------------------------
  # Progress / status classes
  # ------------------------------------------------------------------

  describe "status_indicator_classes/0" do
    test "returns flex classes" do
      result = UIHelpers.status_indicator_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "items-center")
    end
  end

  describe "progress_bar_classes/0" do
    test "returns bar classes with rounded-full" do
      result = UIHelpers.progress_bar_classes()
      assert is_binary(result)
      assert String.contains?(result, "rounded-full")
      assert String.contains?(result, "bg-gray-800")
    end
  end

  describe "progress_bar_fill_classes/0" do
    test "returns fill classes with transition" do
      result = UIHelpers.progress_bar_fill_classes()
      assert is_binary(result)
      assert String.contains?(result, "h-full")
      assert String.contains?(result, "transition")
    end
  end

  # ------------------------------------------------------------------
  # File item classes
  # ------------------------------------------------------------------

  describe "file_item_classes/0" do
    test "returns file item classes with border and hover" do
      result = UIHelpers.file_item_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "border-orange-500")
      assert String.contains?(result, "hover:bg-gray-700")
    end
  end

  describe "file_index_badge_classes/0" do
    test "returns badge classes with rounded-full and orange bg" do
      result = UIHelpers.file_index_badge_classes()
      assert is_binary(result)
      assert String.contains?(result, "bg-orange-500")
      assert String.contains?(result, "rounded-full")
    end
  end

  describe "file_name_classes/0" do
    test "returns name classes with truncate and font-mono" do
      result = UIHelpers.file_name_classes()
      assert is_binary(result)
      assert String.contains?(result, "truncate")
      assert String.contains?(result, "font-mono")
    end
  end

  # ------------------------------------------------------------------
  # Section / text classes
  # ------------------------------------------------------------------

  describe "section_spacing_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.section_spacing_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  describe "section_heading_classes/0" do
    test "returns heading classes with orange and font-bold" do
      result = UIHelpers.section_heading_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-orange-300")
      assert String.contains?(result, "font-bold")
    end
  end

  describe "small_text_classes/0" do
    test "returns small text classes" do
      result = UIHelpers.small_text_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
      assert String.contains?(result, "text-orange-300")
    end
  end

  describe "progress_stats_classes/0" do
    test "returns flex justify-between text classes" do
      result = UIHelpers.progress_stats_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "justify-between")
    end
  end

  describe "eta_text_classes/0" do
    test "returns text classes with center alignment" do
      result = UIHelpers.eta_text_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
      assert String.contains?(result, "text-center")
    end
  end

  describe "crf_vmaf_classes/0" do
    test "returns flex justify-between orange text" do
      result = UIHelpers.crf_vmaf_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "text-orange-400")
    end
  end

  # ------------------------------------------------------------------
  # Loading / dashboard classes
  # ------------------------------------------------------------------

  describe "loading_container_classes/0" do
    test "returns text-center classes" do
      result = UIHelpers.loading_container_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-center")
    end
  end

  describe "dashboard_content_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.dashboard_content_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  describe "control_grid_classes/0" do
    test "returns grid classes" do
      result = UIHelpers.control_grid_classes()
      assert is_binary(result)
      assert String.contains?(result, "grid")
      assert String.contains?(result, "gap")
    end
  end

  describe "loading_indicator_classes/0" do
    test "returns text-center indicator classes" do
      result = UIHelpers.loading_indicator_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-center")
      assert String.contains?(result, "text-sm")
    end
  end

  describe "loading_animation_classes/0" do
    test "returns animate-pulse flex classes" do
      result = UIHelpers.loading_animation_classes()
      assert is_binary(result)
      assert String.contains?(result, "animate-pulse")
      assert String.contains?(result, "flex")
    end
  end

  describe "bounce_dot_classes/0" do
    test "returns dot classes with rounded-full" do
      result = UIHelpers.bounce_dot_classes()
      assert is_binary(result)
      assert String.contains?(result, "rounded-full")
      assert String.contains?(result, "bg-current")
    end
  end

  # ------------------------------------------------------------------
  # Operation classes
  # ------------------------------------------------------------------

  describe "operation_title_classes/0" do
    test "returns title classes with rounded and flex" do
      result = UIHelpers.operation_title_classes()
      assert is_binary(result)
      assert String.contains?(result, "rounded")
      assert String.contains?(result, "flex")
    end
  end

  describe "operation_status_spacing_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.operation_status_spacing_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  describe "operation_content_spacing_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.operation_content_spacing_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  describe "file_estimation_classes/0" do
    test "returns text and flex classes" do
      result = UIHelpers.file_estimation_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
      assert String.contains?(result, "flex")
    end
  end

  # ------------------------------------------------------------------
  # Estimation / file detail classes
  # ------------------------------------------------------------------

  describe "estimation_dot_classes/0" do
    test "returns dot classes with animate-pulse" do
      result = UIHelpers.estimation_dot_classes()
      assert is_binary(result)
      assert String.contains?(result, "rounded-full")
      assert String.contains?(result, "animate-pulse")
    end
  end

  describe "file_details_classes/0" do
    test "returns flex-1 and space-y" do
      result = UIHelpers.file_details_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex-1")
      assert String.contains?(result, "space-y")
    end
  end

  describe "file_metadata_classes/0" do
    test "returns text-xs classes" do
      result = UIHelpers.file_metadata_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
    end
  end

  # ------------------------------------------------------------------
  # Progress display classes
  # ------------------------------------------------------------------

  describe "progress_filename_classes/0" do
    test "returns text and truncate classes" do
      result = UIHelpers.progress_filename_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
      assert String.contains?(result, "truncate")
    end
  end

  describe "progress_display_spacing_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.progress_display_spacing_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  # ------------------------------------------------------------------
  # Analyzer classes
  # ------------------------------------------------------------------

  describe "analyzer_stats_classes/0" do
    test "returns text-xs and space-y classes" do
      result = UIHelpers.analyzer_stats_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
      assert String.contains?(result, "space-y")
    end
  end

  describe "analyzer_rate_classes/0" do
    test "returns flex justify-between" do
      result = UIHelpers.analyzer_rate_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "justify-between")
    end
  end

  describe "analyzer_throughput_classes/0" do
    test "returns text-center classes" do
      result = UIHelpers.analyzer_throughput_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-center")
    end
  end

  # ------------------------------------------------------------------
  # Queue overflow / content classes
  # ------------------------------------------------------------------

  describe "queue_overflow_classes/0" do
    test "returns text-center and padding" do
      result = UIHelpers.queue_overflow_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-center")
    end
  end

  describe "queue_overflow_text_classes/0" do
    test "returns text-xs orange classes" do
      result = UIHelpers.queue_overflow_text_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
      assert String.contains?(result, "text-orange-300")
    end
  end

  describe "queue_items_container_classes/0" do
    test "returns overflow and space-y classes" do
      result = UIHelpers.queue_items_container_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
      assert String.contains?(result, "overflow-y-auto")
    end
  end

  describe "empty_queue_classes/0" do
    test "returns text-center and padding" do
      result = UIHelpers.empty_queue_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-center")
    end
  end

  describe "empty_queue_icon_classes/0" do
    test "returns text size classes" do
      result = UIHelpers.empty_queue_icon_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-3xl")
    end
  end

  describe "empty_queue_text_classes/0" do
    test "returns text-orange-300 classes" do
      result = UIHelpers.empty_queue_text_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-orange-300")
    end
  end

  # ------------------------------------------------------------------
  # Badge / index / file display classes
  # ------------------------------------------------------------------

  describe "badge_text_classes/0" do
    test "returns font-bold text-black classes" do
      result = UIHelpers.badge_text_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-black")
      assert String.contains?(result, "font-bold")
    end
  end

  describe "estimation_indicator_classes/0" do
    test "returns animate-pulse dot classes" do
      result = UIHelpers.estimation_indicator_classes()
      assert is_binary(result)
      assert String.contains?(result, "rounded-full")
      assert String.contains?(result, "animate-pulse")
    end
  end

  describe "file_name_display_classes/0" do
    test "returns flex classes" do
      result = UIHelpers.file_name_display_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "items-center")
    end
  end

  describe "filename_text_classes/0" do
    test "returns font-medium and truncate classes" do
      result = UIHelpers.filename_text_classes()
      assert is_binary(result)
      assert String.contains?(result, "font-medium")
      assert String.contains?(result, "truncate")
    end
  end

  describe "path_change_indicator_classes/0" do
    test "returns text-xs classes" do
      result = UIHelpers.path_change_indicator_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-xs")
    end
  end

  # ------------------------------------------------------------------
  # Queue structure / count classes
  # ------------------------------------------------------------------

  describe "queue_count_container_classes/0" do
    test "returns margin classes" do
      result = UIHelpers.queue_count_container_classes()
      assert is_binary(result)
      assert String.contains?(result, "ml-2")
    end
  end

  describe "queue_count_text_classes/0" do
    test "returns font-bold text classes" do
      result = UIHelpers.queue_count_text_classes()
      assert is_binary(result)
      assert String.contains?(result, "font-bold")
      assert String.contains?(result, "text-black")
    end
  end

  describe "queue_content_padding_classes/0" do
    test "returns padding and flex classes" do
      result = UIHelpers.queue_content_padding_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "flex-col")
    end
  end

  # ------------------------------------------------------------------
  # Metadata display classes
  # ------------------------------------------------------------------

  describe "metadata_item_classes/0" do
    test "returns flex and text-xs classes" do
      result = UIHelpers.metadata_item_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "text-xs")
    end
  end

  describe "metadata_label_classes/0" do
    test "returns font-medium classes" do
      result = UIHelpers.metadata_label_classes()
      assert is_binary(result)
      assert String.contains?(result, "font-medium")
    end
  end

  describe "metadata_value_classes/0" do
    test "returns font-mono font-semibold" do
      result = UIHelpers.metadata_value_classes()
      assert is_binary(result)
      assert String.contains?(result, "font-mono")
      assert String.contains?(result, "font-semibold")
    end
  end

  # ------------------------------------------------------------------
  # Control panel / operations section classes
  # ------------------------------------------------------------------

  describe "control_panel_content_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.control_panel_content_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  describe "operations_section_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.operations_section_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  describe "operations_heading_classes/0" do
    test "returns orange heading classes" do
      result = UIHelpers.operations_heading_classes()
      assert is_binary(result)
      assert String.contains?(result, "text-orange-300")
      assert String.contains?(result, "font-bold")
    end
  end

  # ------------------------------------------------------------------
  # Status / dashboard layout classes
  # ------------------------------------------------------------------

  describe "status_indicator_container_classes/0" do
    test "returns flex and items-center" do
      result = UIHelpers.status_indicator_container_classes()
      assert is_binary(result)
      assert String.contains?(result, "flex")
      assert String.contains?(result, "items-center")
    end
  end

  describe "dashboard_section_spacing_classes/0" do
    test "returns spacing classes" do
      result = UIHelpers.dashboard_section_spacing_classes()
      assert is_binary(result)
      assert String.contains?(result, "space-y")
    end
  end

  describe "dashboard_bottom_grid_classes/0" do
    test "returns grid with gap classes" do
      result = UIHelpers.dashboard_bottom_grid_classes()
      assert is_binary(result)
      assert String.contains?(result, "grid")
      assert String.contains?(result, "gap")
    end
  end

  # ------------------------------------------------------------------
  # stats_config/0
  # ------------------------------------------------------------------

  describe "stats_config/0" do
    test "returns a list of 4 stat configs" do
      result = UIHelpers.stats_config()
      assert is_list(result)
      assert length(result) == 4
    end

    test "each config has label and key" do
      Enum.each(UIHelpers.stats_config(), fn config ->
        assert Map.has_key?(config, :label)
        assert Map.has_key?(config, :key)
      end)
    end
  end
end
