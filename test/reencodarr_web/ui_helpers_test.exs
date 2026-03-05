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
end
