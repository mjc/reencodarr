defmodule ReencodarrWeb.QueueInfoComponent do
  use Phoenix.LiveComponent

  attr :stats, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between">
        <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
          <span>CRF Searches in Queue</span>
          <span class="ml-1 text-xs text-gray-400" title="Number of CRF search jobs waiting.">?</span>
        </div>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
          {@stats.queue_length.crf_searches}
        </div>
      </div>
      <div class="flex items-center justify-between">
        <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
          <span>Encodes in Queue</span>
          <span class="ml-1 text-xs text-gray-400" title="Number of encoding jobs waiting.">?</span>
        </div>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
          {@stats.queue_length.encodes}
        </div>
      </div>
    </div>
    """
  end
end
