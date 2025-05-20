defmodule ReencodarrWeb.SyncProgressComponent do
  use Phoenix.LiveComponent

  attr :sync_progress, :integer, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 mb-1">Sync Progress</div>
      <div class="flex items-center space-x-2">
        <div class="w-full bg-gray-600 rounded-full h-2.5 dark:bg-gray-500">
          <div
            class="bg-indigo-600 h-2.5 rounded-full transition-all duration-300"
            style={"width: #{if @sync_progress > 0, do: @sync_progress, else: 0}%"}
          >
          </div>
        </div>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
          <strong><%= @sync_progress %>%</strong>
        </div>
      </div>
    </div>
    """
  end
end
