defmodule ReencodarrWeb.ManualScanComponent do
  use Phoenix.LiveComponent
  require Logger

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full max-w-2xl flex justify-center mb-6">
      <form phx-submit="manual_scan" phx-target={@myself} class="flex items-center space-x-2 w-full">
        <input
          type="text"
          name="path"
          placeholder="Enter path to scan"
          class="input px-4 py-2 rounded shadow border border-gray-600 dark:border-gray-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 w-full bg-gray-900 text-gray-100"
        />
        <button
          type="submit"
          class="text-white font-bold py-2 px-4 rounded shadow bg-indigo-500 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500"
        >
          Start Manual Scan
        </button>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("manual_scan", %{"path" => path}, socket) do
    Logger.info("Starting manual scan for path: #{path}")
    Reencodarr.ManualScanner.scan(path)
    {:noreply, socket}
  end
end
