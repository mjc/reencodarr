defmodule ReencodarrWeb.SummaryRowComponent do
  use Phoenix.LiveComponent

  attr :stats, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full max-w-6xl grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
      <div class="bg-indigo-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-indigo-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path d="M9 17v-2a4 4 0 1 1 8 0v2"></path>
          <circle cx="12" cy="7" r="4"></circle>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.total_videos}</div>
          <div class="text-xs text-indigo-100">Total Videos</div>
        </div>
      </div>
      <div class="bg-green-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-green-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path d="M5 13l4 4L19 7"></path>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.reencoded}</div>
          <div class="text-xs text-green-100">Reencoded</div>
        </div>
      </div>
      <div class="bg-yellow-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-yellow-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <circle cx="12" cy="12" r="10"></circle>
          <path d="M12 8v4l3 3"></path>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.not_reencoded}</div>
          <div class="text-xs text-yellow-100">Not Reencoded</div>
        </div>
      </div>
      <div class="bg-blue-700/80 rounded-lg shadow flex items-center p-4 space-x-4">
        <svg
          class="w-8 h-8 text-blue-200"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <rect width="20" height="14" x="2" y="5" rx="2"></rect>
          <path d="M2 10h20"></path>
        </svg>
        <div>
          <div class="text-lg font-bold text-white">{assigns.stats.queue_length.encodes}</div>
          <div class="text-xs text-blue-100">Encodes in Queue</div>
        </div>
      </div>
    </div>
    """
  end
end
