defmodule ReencodarrWeb.QueueInformationComponent do
  use Phoenix.LiveComponent

  attr :stats, :map, required: true

  @impl true
  def render(assigns) do
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
  end
end
