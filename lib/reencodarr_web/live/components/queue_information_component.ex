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
      <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
        <h2 class="text-2xl font-bold text-indigo-500 mb-4">
          Queue Information
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
