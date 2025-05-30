defmodule ReencodarrWeb.QueueInformationComponent do
  use Phoenix.LiveComponent

  require Logger

  attr :stats, :map, required: true

  # Document PubSub topics related to queue information
  @doc "Handles queue information updates broadcasted via PubSub"
  # Render queue information component
  @impl true
  def render(assigns) do
    if is_map(assigns.stats) do
      ~H"""
      <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
        <h2 class="text-lg font-bold mb-4 text-indigo-300 flex items-center space-x-2">
          <svg
            class="w-5 h-5 text-indigo-400"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <rect width="20" height="14" x="2" y="5" rx="2"></rect>
            <path d="M2 10h20"></path>
          </svg>
          <span>Queue Information</span>
        </h2>
        <div class="flex flex-col space-y-4">
          <.live_component module={ReencodarrWeb.QueueInfoComponent} id="queue-info" stats={@stats} />
        </div>
      </div>
      """
    else
      Logger.error("Invalid stats received for queue information: #{inspect(assigns.stats)}")

      ~H"""
      <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
        <h2 class="text-lg font-bold mb-4 text-red-500">Error: Invalid Queue Information</h2>
      </div>
      """
    end
  end
end
