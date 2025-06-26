defmodule ReencodarrWeb.ControlButtonsComponent do
  use Phoenix.LiveComponent

  require Logger

  @doc "Handles toggle and sync events broadcasted via PubSub"
  @impl true
  def mount(socket) do
    encoding = Reencodarr.Encoder.Producer.running?()
    crf_searching = Reencodarr.CrfSearcher.Producer.running?()
    {:ok, assign(socket, encoding: encoding, crf_searching: crf_searching, syncing: false)}
  end

  @impl true
  def update(assigns, socket) do
    # Ensure syncing state is updated correctly
    socket =
      socket
      |> assign(:encoding, Map.get(assigns, :encoding, false))
      |> assign(:crf_searching, Map.get(assigns, :crf_searching, false))
      |> assign(:syncing, Map.get(assigns, :syncing, false))

    {:ok, socket}
  end

  defp toggle_app(app, type, socket) do
    Logger.info("Toggling #{type}")
    new_state = not Map.get(socket.assigns, type)

    if new_state, do: app.start(), else: app.pause()
    {:noreply, assign(socket, type, new_state)}
  end

  # Group PubSub topics and document their purpose

  # Handle toggle events for encoder and CRF search
  @impl true
  def handle_event("toggle", %{"target" => target}, socket) do
    case target do
      "encoder" ->
        toggle_app(Reencodarr.Encoder.Producer, :encoding, socket)

      "crf_search" ->
        toggle_app(Reencodarr.CrfSearcher.Producer, :crf_searching, socket)

      _ ->
        Logger.error("Unknown toggle target: #{inspect(target)}")
        {:noreply, socket}
    end
  end

  # Handle sync events for Sonarr and Radarr
  @impl true
  def handle_event("sync", %{"target" => target}, socket) do
    case target do
      "sonarr" ->
        Reencodarr.Sync.sync_episodes()

      "radarr" ->
        Reencodarr.Sync.sync_movies()

      _ ->
        Logger.error("Unknown sync target: #{inspect(target)}")
        :noop
    end

    {:noreply, assign(socket, :syncing, true)}
  end

  # Helper functions for CSS classes
  defp button_classes(base_classes, condition, active_classes, inactive_classes) do
    base_classes <> " " <> if condition, do: active_classes, else: inactive_classes
  end

  defp toggle_button_classes(is_active, active_color, inactive_color) do
    base = "group relative overflow-hidden rounded-xl px-4 py-3 font-semibold text-white transition-all duration-200 transform hover:scale-105 focus:outline-none focus:ring-2 focus:ring-white/50 focus:ring-offset-2 focus:ring-offset-transparent"

    active_classes = color_classes(active_color)
    inactive_classes = color_classes(inactive_color)

    button_classes(base, is_active, active_classes, inactive_classes)
  end

  defp sync_button_classes(is_syncing, color) do
    base = "group relative overflow-hidden rounded-xl px-4 py-3 font-semibold text-white transition-all duration-200 transform hover:scale-105 focus:outline-none focus:ring-2 focus:ring-white/50 focus:ring-offset-2 focus:ring-offset-transparent"

    disabled_classes = "bg-gradient-to-r from-slate-500 to-slate-600 cursor-not-allowed opacity-50"
    active_classes = color_classes(color)

    button_classes(base, is_syncing, disabled_classes, active_classes)
  end

  # Map color names to actual Tailwind classes with modern styling
  defp color_classes("red"), do: "bg-gradient-to-r from-red-500 to-red-600 hover:from-red-600 hover:to-red-700 shadow-lg shadow-red-500/25"
  defp color_classes("indigo"), do: "bg-gradient-to-r from-indigo-500 to-indigo-600 hover:from-indigo-600 hover:to-indigo-700 shadow-lg shadow-indigo-500/25"
  defp color_classes("green"), do: "bg-gradient-to-r from-emerald-500 to-emerald-600 hover:from-emerald-600 hover:to-emerald-700 shadow-lg shadow-emerald-500/25"
  defp color_classes("yellow"), do: "bg-gradient-to-r from-amber-500 to-amber-600 hover:from-amber-600 hover:to-amber-700 shadow-lg shadow-amber-500/25"
  defp color_classes("blue"), do: "bg-gradient-to-r from-blue-500 to-blue-600 hover:from-blue-600 hover:to-blue-700 shadow-lg shadow-blue-500/25"
  defp color_classes("purple"), do: "bg-gradient-to-r from-purple-500 to-purple-600 hover:from-purple-600 hover:to-purple-700 shadow-lg shadow-purple-500/25"
  defp color_classes("pink"), do: "bg-gradient-to-r from-pink-500 to-pink-600 hover:from-pink-600 hover:to-pink-700 shadow-lg shadow-pink-500/25"
  defp color_classes("gray"), do: "bg-gradient-to-r from-slate-500 to-slate-600 hover:from-slate-600 hover:to-slate-700 shadow-lg shadow-slate-500/25"
  # Fallback for unknown colors
  defp color_classes(_), do: "bg-gradient-to-r from-slate-500 to-slate-600 hover:from-slate-600 hover:to-slate-700 shadow-lg shadow-slate-500/25"

  defp toggle_button_text(is_active, active_text, inactive_text) do
    if is_active, do: active_text, else: inactive_text
  end

  # Define button configurations as data
  defp button_configs(assigns) do
    [
      %{
        type: :toggle,
        target: "encoder",
        state: assigns.encoding,
        colors: {"red", "indigo"},
        active_text: "Pause Encoder",
        inactive_text: "Start Encoder"
      },
      %{
        type: :toggle,
        target: "crf_search",
        state: assigns.crf_searching,
        colors: {"red", "green"},
        active_text: "Pause CRF Search",
        inactive_text: "Start CRF Search"
      },
      %{
        type: :sync,
        target: "sonarr",
        disabled: assigns.syncing,
        color: "yellow",
        text: "Sync Sonarr"
      },
      %{
        type: :sync,
        target: "radarr",
        disabled: assigns.syncing,
        color: "green",
        text: "Sync Radarr"
      }
    ]
  end

  defp render_button(%{type: :toggle} = config, assigns) do
    {active_color, inactive_color} = config.colors
    assigns = assigns
      |> assign(:config, config)
      |> assign(:active_color, active_color)
      |> assign(:inactive_color, inactive_color)
      |> assign(:button_classes, toggle_button_classes(config.state, active_color, inactive_color))
      |> assign(:button_title, if(config.state, do: config.active_text, else: config.inactive_text))
      |> assign(:button_text, toggle_button_text(config.state, config.active_text, config.inactive_text))

    ~H"""
    <button
      phx-click="toggle"
      phx-target={@myself}
      phx-value-target={@config.target}
      class={@button_classes}
      title={@button_title}
    >
      <!-- Background glow effect -->
      <div class="absolute inset-0 bg-white/10 rounded-xl opacity-0 group-hover:opacity-100 transition-opacity duration-200"></div>

      <div class="relative flex items-center space-x-2">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
          <%= if @config.state do %>
            <rect x="6" y="4" width="4" height="16" rx="1" />
            <rect x="14" y="4" width="4" height="16" rx="1" />
          <% else %>
            <polygon points="5,3 19,12 5,21 5,3" />
          <% end %>
        </svg>
        <span class="text-sm font-medium">{@button_text}</span>
      </div>
    </button>
    """
  end

  defp render_button(%{type: :sync} = config, assigns) do
    assigns = assigns
      |> assign(:config, config)
      |> assign(:button_classes, sync_button_classes(config.disabled, config.color))

    ~H"""
    <button
      phx-click="sync"
      phx-target={@myself}
      phx-value-target={@config.target}
      class={@button_classes}
      disabled={@config.disabled}
      title={@config.text}
    >
      <!-- Background glow effect -->
      <div class="absolute inset-0 bg-white/10 rounded-xl opacity-0 group-hover:opacity-100 transition-opacity duration-200"></div>

      <div class="relative flex items-center space-x-2">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
          <path d="M4 4v5h.582M20 20v-5h-.581M5 9A7 7 0 0 1 19 15M19 15V9M5 9v6" />
        </svg>
        <span class="text-sm font-medium">{@config.text}</span>
      </div>
    </button>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <%= for config <- button_configs(assigns) do %>
        {render_button(config, assigns)}
      <% end %>
    </div>
    """
  end
end
