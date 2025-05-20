defmodule ReencodarrWeb.ProgressInformationComponent do
  use Phoenix.LiveComponent

  attr :encoding_progress, :map, required: true
  attr :crf_search_progress, :map, required: true
  attr :sync_progress, :integer, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
      <h2 class="text-lg font-bold mb-4 text-green-300 flex items-center space-x-2">
        <svg
          class="w-5 h-5 text-green-400"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path d="M3 12h18"></path>
          <path d="M12 3v18"></path>
        </svg>
        <span>Progress Information</span>
      </h2>
      <div class="flex flex-col space-y-4">
        <.live_component
          module={ReencodarrWeb.EncodingProgressComponent}
          id="encoding-progress"
          encoding_progress={@encoding_progress}
        />
        <.live_component
          module={ReencodarrWeb.CrfSearchProgressComponent}
          id="crf-search-progress"
          crf_search_progress={@crf_search_progress}
        />
        <.live_component
          module={ReencodarrWeb.SyncProgressComponent}
          id="sync-progress"
          sync_progress={@sync_progress}
        />
      </div>
    </div>
    """
  end
end
