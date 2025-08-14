defmodule ReencodarrWeb.CssHelpers do
  @moduledoc """
  Consolidated CSS class utilities for common UI patterns.

  This module eliminates duplication by providing reusable CSS class
  generators for common button and component styling patterns used
  throughout the application.
  """

  @doc """
  Generates CSS classes for filter buttons.

  Returns the appropriate classes based on whether the button is active or not.
  Used for filter buttons throughout the application.

  ## Examples

      iex> filter_button_class(true)
      "px-3 py-1 text-xs rounded transition-colors bg-orange-500 text-black"

      iex> filter_button_class(false)
      "px-3 py-1 text-xs rounded transition-colors bg-gray-700 text-orange-400 hover:bg-orange-600"

      iex> filter_button_class(true, :blue)
      "px-3 py-1 text-xs rounded transition-colors bg-blue-500 text-white"

  """
  def filter_button_class(is_active, color_scheme \\ :orange) do
    base_classes = "px-3 py-1 text-xs rounded transition-colors"
    
    active_state = case {is_active, color_scheme} do
      {true, :orange} -> "bg-orange-500 text-black"
      {false, :orange} -> "bg-gray-700 text-orange-400 hover:bg-orange-600"
      {true, :blue} -> "bg-blue-500 text-white"
      {false, :blue} -> "bg-gray-700 text-blue-400 hover:bg-blue-600"
      {true, :green} -> "bg-green-500 text-white"
      {false, :green} -> "bg-gray-700 text-green-400 hover:bg-green-600"
      {true, :red} -> "bg-red-500 text-white"
      {false, :red} -> "bg-gray-700 text-red-400 hover:bg-red-600"
    end
    
    "#{base_classes} #{active_state}"
  end

  @doc """
  Generates CSS classes for pagination buttons.

  Similar to filter buttons but slightly different base styling.

  ## Examples

      iex> pagination_button_class(true)
      "px-2 py-1 text-xs rounded transition-colors bg-orange-500 text-black"

      iex> pagination_button_class(false)
      "px-2 py-1 text-xs rounded transition-colors bg-gray-700 text-orange-400 hover:bg-orange-600"

  """
  def pagination_button_class(is_active) do
    base_classes = "px-2 py-1 text-xs rounded transition-colors"
    
    active_state = if is_active do
      "bg-orange-500 text-black"
    else
      "bg-gray-700 text-orange-400 hover:bg-orange-600"
    end
    
    "#{base_classes} #{active_state}"
  end

  @doc """
  Generates CSS classes for action buttons.

  Standard styling for action buttons like delete, retry, etc.

  ## Examples

      iex> action_button_class()
      "px-2 py-1 bg-gray-700 text-orange-400 text-xs rounded hover:bg-orange-600 transition-colors"

  """
  def action_button_class do
    "px-2 py-1 bg-gray-700 text-orange-400 text-xs rounded hover:bg-orange-600 transition-colors"
  end

  @doc """
  Generates CSS classes for status badges.

  Returns different styling based on status type.

  ## Examples

      iex> status_badge_class(:success)
      "px-2 py-1 text-xs rounded bg-green-600 text-white"

      iex> status_badge_class(:error)
      "px-2 py-1 text-xs rounded bg-red-600 text-white"

      iex> status_badge_class(:warning)
      "px-2 py-1 text-xs rounded bg-yellow-600 text-black"

      iex> status_badge_class(:info)
      "px-2 py-1 text-xs rounded bg-blue-600 text-white"

  """
  def status_badge_class(status) do
    base_classes = "px-2 py-1 text-xs rounded"
    
    status_classes = case status do
      :success -> "bg-green-600 text-white"
      :error -> "bg-red-600 text-white"
      :warning -> "bg-yellow-600 text-black"
      :info -> "bg-blue-600 text-white"
      _ -> "bg-gray-600 text-white"
    end
    
    "#{base_classes} #{status_classes}"
  end
end
