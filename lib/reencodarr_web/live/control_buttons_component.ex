defmodule ReencodarrWeb.ControlButtonsComponent do
  use Phoenix.LiveComponent

  require Logger

  @impl true
  def mount(socket) do
    encoding = Reencodarr.Encoder.running?()
    crf_searching = Reencodarr.CrfSearcher.running?()
    {:ok, assign(socket, encoding: encoding, crf_searching: crf_searching, syncing: false)}
  end

  @impl true
  def update(assigns, socket) do
    # Allow parent to override state if needed
    socket =
      socket
      |> assign_new(:encoding, fn -> Map.get(assigns, :encoding, false) end)
      |> assign_new(:crf_searching, fn -> Map.get(assigns, :crf_searching, false) end)
      |> assign_new(:syncing, fn -> Map.get(assigns, :syncing, false) end)

    {:ok, socket}
  end

  defp toggle_app(app, type, socket) do
    Logger.info("Toggling #{type}")
    new_state = not Map.get(socket.assigns, type)

    if new_state, do: app.start(), else: app.pause()
    {:noreply, assign(socket, type, new_state)}
  end

  @impl true
  def handle_event("toggle", %{"target" => target}, socket) do
    case target do
      "encoder" ->
        toggle_app(Reencodarr.Encoder, :encoding, socket)

      "crf_search" ->
        toggle_app(Reencodarr.CrfSearcher, :crf_searching, socket)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("sync", %{"target" => target}, socket) do
    case target do
      "sonarr" -> Reencodarr.Sync.sync_episodes()
      "radarr" -> Reencodarr.Sync.sync_movies()
      _ -> :noop
    end
    {:noreply, assign(socket, :syncing, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <button
        phx-click="toggle"
        phx-target={@myself}
        phx-value-target="encoder"
        class={"flex items-center space-x-2 px-4 py-2 rounded-lg shadow font-semibold focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @encoding, do: "bg-red-500 hover:bg-red-600 focus:ring-red-500", else: "bg-indigo-500 hover:bg-indigo-600 focus:ring-indigo-500"}
        title={if @encoding, do: "Pause Encoder", else: "Start Encoder"}
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <%= if @encoding do %>
            <rect x="6" y="4" width="4" height="16" rx="1" />
            <rect x="14" y="4" width="4" height="16" rx="1" />
          <% else %>
            <polygon points="5,3 19,12 5,21 5,3" />
          <% end %>
        </svg>
        <span>{(@encoding && "Pause Encoder") || "Start Encoder"}</span>
      </button>
      <button
        phx-click="toggle"
        phx-target={@myself}
        phx-value-target="crf_search"
        class={"flex items-center space-x-2 px-4 py-2 rounded-lg shadow font-semibold focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @crf_searching, do: "bg-red-500 hover:bg-red-600 focus:ring-red-500", else: "bg-green-500 hover:bg-green-600 focus:ring-green-500"}
        title={if @crf_searching, do: "Pause CRF Search", else: "Start CRF Search"}
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <%= if @crf_searching do %>
            <rect x="6" y="4" width="4" height="16" rx="1" />
            <rect x="14" y="4" width="4" height="16" rx="1" />
          <% else %>
            <polygon points="5,3 19,12 5,21 5,3" />
          <% end %>
        </svg>
        <span>{(@crf_searching && "Pause CRF Search") || "Start CRF Search"}</span>
      </button>
      <button
        phx-click="sync"
        phx-target={@myself}
        phx-value-target="sonarr"
        class={"flex items-center space-x-2 font-semibold px-4 py-2 rounded-lg shadow focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @syncing, do: "bg-gray-500 focus:ring-gray-500 cursor-not-allowed", else: "bg-yellow-500 hover:bg-yellow-600 focus:ring-yellow-500"}
        disabled={@syncing}
        title="Sync Sonarr"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <path d="M4 4v5h.582M20 20v-5h-.581M5 9A7 7 0 0 1 19 15M19 15V9M5 9v6" />
        </svg>
        <span>Sync Sonarr</span>
      </button>
      <button
        phx-click="sync"
        phx-target={@myself}
        phx-value-target="radarr"
        class={"flex items-center space-x-2 font-semibold px-4 py-2 rounded-lg shadow focus:outline-none focus:ring-2 transition-all duration-150 " <>
          if @syncing, do: "bg-gray-500 focus:ring-gray-500 cursor-not-allowed", else: "bg-green-500 hover:bg-green-600 focus:ring-green-500"}
        disabled={@syncing}
        title="Sync Radarr"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <path d="M4 4v5h.582M20 20v-5h-.581M5 9A7 7 0 0 1 19 15M19 15V9M5 9v6" />
        </svg>
        <span>Sync Radarr</span>
      </button>
    </div>
    """
  end
end
