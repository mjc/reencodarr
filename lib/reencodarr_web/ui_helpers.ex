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
end
