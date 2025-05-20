defmodule ReencodarrWeb.CrfSearchProgressComponent do
  use Phoenix.LiveComponent

  attr :crf_search_progress, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 mb-1">
        CRF Search Progress
      </div>
      <%= if @crf_search_progress.filename != :none do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold"><%= @crf_search_progress.filename %></span>
        </div>
        <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
          <ul class="list-disc pl-5 fancy-list">
            <li>CRF: <strong><%= @crf_search_progress.crf %></strong></li>
            <li>
              Percent: <strong><%= @crf_search_progress.percent %>%</strong> (of original size)
            </li>
            <li>VMAF Score: <strong><%= @crf_search_progress.score %></strong> (Target: 95)</li>
          </ul>
        </div>
      <% else %>
        <div class="text-sm leading-5 text-gray-400 dark:text-gray-300">
          No CRF search in progress
        </div>
      <% end %>
    </div>
    """
  end
end
