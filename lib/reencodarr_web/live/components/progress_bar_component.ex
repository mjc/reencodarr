defmodule ReencodarrWeb.ProgressBarComponent do
  @moduledoc """
  A reusable progress bar component with consistent styling and behavior.

  This component provides a standardized progress bar that can be used across
  different progress tracking scenarios (encoding, CRF search, sync, etc.).
  """
  use Phoenix.LiveComponent

  attr :percent, :integer, required: true, doc: "Progress percentage (0-100)"
  attr :color, :string, default: "indigo", doc: "Color theme: indigo, purple, green, etc."
  attr :class, :string, default: "", doc: "Additional CSS classes"
  attr :show_text, :boolean, default: true, doc: "Whether to show percentage text"
  attr :id, :string, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"flex items-center space-x-2 #{@class}"}>
      <div class="w-full bg-gray-600 rounded-full h-2.5 dark:bg-gray-500">
        <div
          class={"bg-#{@color}-600 h-2.5 rounded-full transition-all duration-300"}
          style={"width: #{max(@percent, 0)}%"}
        >
        </div>
      </div>
      <%= if @show_text do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
          <strong>{@percent}%</strong>
        </div>
      <% end %>
    </div>
    """
  end
end
