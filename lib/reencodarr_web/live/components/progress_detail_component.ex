defmodule ReencodarrWeb.ProgressDetailComponent do
  @moduledoc """
  A reusable component for displaying progress details in a consistent format.

  This component handles the common pattern of showing progress information
  with title, details list, and optional progress bar.
  """
  use Phoenix.LiveComponent

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :details, :list, default: []
  attr :progress_percent, :integer, default: nil
  attr :progress_color, :string, default: "indigo"
  attr :show_when_inactive, :boolean, default: true
  attr :inactive_message, :string, default: "No operation in progress"
  attr :class, :string, default: ""
  attr :id, :string, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@class}>
      <%= if has_active_progress?(assigns) do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">{@title}</span>
          <%= if @subtitle do %>
            <span class="font-mono">{@subtitle}</span>
          <% end %>
          <%= if @progress_percent do %>
            - {@progress_percent}%
          <% end %>
        </div>

        <%= if @details != [] do %>
          <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
            <ul class="list-disc pl-5 fancy-list">
              <%= for detail <- @details do %>
                <li>{detail}</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <%= if @progress_percent do %>
          <.live_component
            module={ReencodarrWeb.ProgressBarComponent}
            id={"#{@id}-progress-bar"}
            percent={@progress_percent}
            color={@progress_color}
          />
        <% end %>
      <% else %>
        <%= if @show_when_inactive do %>
          <div class="text-sm leading-5 text-gray-400 dark:text-gray-300">
            {@inactive_message}
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp has_active_progress?(assigns) do
    # Consider progress active if we have a meaningful title and either details or progress
    assigns.title != nil and (assigns.details != [] or assigns.progress_percent != nil)
  end
end
