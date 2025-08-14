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

    state_classes = case {is_active, color_scheme} do
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

    status_classes = case status do
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
    border_color = case color do
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
end
