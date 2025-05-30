defmodule ReencodarrWeb.ProgressInformationComponent do
  use Phoenix.LiveComponent

  attr :encoding_progress, :map, required: true
  attr :crf_search_progress, :map, required: true
  attr :sync_progress, :integer, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full bg-gray-900 rounded-xl shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        Progress Information
      </h2>
      <div class="flex flex-col space-y-6">
        <.live_component
          module={ReencodarrWeb.EncodingProgressComponent}
          id="encoding-progress"
          encoding_progress={@encoding_progress}
          class="bg-gray-800 rounded-lg p-4 shadow-md hover:bg-gray-700 transition-colors duration-200"
        />
        <.live_component
          module={ReencodarrWeb.CrfSearchProgressComponent}
          id="crf-search-progress"
          crf_search_progress={@crf_search_progress}
          class="bg-gray-800 rounded-lg p-4 shadow-md hover:bg-gray-700 transition-colors duration-200"
        />
        <.live_component
          module={ReencodarrWeb.SyncProgressComponent}
          id="sync-progress"
          sync_progress={@sync_progress}
          class="bg-gray-800 rounded-lg p-4 shadow-md hover:bg-gray-700 transition-colors duration-200"
        />
      </div>
    </div>
    """
  end
end
