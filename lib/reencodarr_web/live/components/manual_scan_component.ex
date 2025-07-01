defmodule ReencodarrWeb.ManualScanComponent do
  use Phoenix.LiveComponent
  require Logger

  @moduledoc "Handles manual scanning of media files."

  @doc "Handles manual scan events broadcasted via PubSub"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <form phx-submit="manual_scan" phx-target={@myself} class="space-y-3">
        <div class="space-y-2">
          <label class="block text-orange-300 text-sm font-bold tracking-wide">
            SCAN PATH
          </label>
          <input
            type="text"
            name="path"
            placeholder="/path/to/media/files"
            class="w-full px-4 py-3 bg-gray-800 border-2 border-orange-500 rounded font-mono text-orange-400 placeholder-orange-600 focus:outline-none focus:border-yellow-400 focus:bg-gray-700 transition-all duration-200"
          />
        </div>

        <button
          type="submit"
          class="w-full h-12 bg-red-500 hover:bg-red-400 text-black font-bold tracking-wider rounded transition-all duration-200 hover:brightness-110 flex items-center justify-center space-x-2"
        >
          <span>🔍</span>
          <span>INITIATE SCAN</span>
        </button>
      </form>

      <div class="text-xs text-orange-300 tracking-wide space-y-1">
        <p>• SPECIFY FULL PATH TO MEDIA DIRECTORY</p>
        <p>• SCAN WILL PROCESS ALL VIDEO FILES RECURSIVELY</p>
        <p>• OPERATION MAY TAKE SEVERAL MINUTES</p>
      </div>
    </div>
    """
  end

  # Document PubSub topics related to manual scanning

  # Handle manual scan events
  @impl true
  def handle_event("manual_scan", %{"path" => path}, socket) do
    if is_binary(path) do
      Logger.info("Starting manual scan for path: #{path}")
      Reencodarr.ManualScanner.scan(path)
      {:noreply, socket}
    else
      Logger.error("Invalid path received for manual scan: #{inspect(path)}")
      {:noreply, socket}
    end
  end
end
