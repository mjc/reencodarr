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
    base = "flex items-center space-x-2 px-4 py-2 rounded-lg shadow font-semibold focus:outline-none focus:ring-2 transition-all duration-150"

    active_classes = color_classes(active_color)
    inactive_classes = color_classes(inactive_color)

    button_classes(base, is_active, active_classes, inactive_classes)
  end

  defp sync_button_classes(is_syncing, color) do
    base = "flex items-center space-x-2 font-semibold px-4 py-2 rounded-lg shadow focus:outline-none focus:ring-2 transition-all duration-150"

    disabled_classes = "bg-gray-500 hover:bg-gray-600 focus:ring-gray-500 cursor-not-allowed"
    active_classes = color_classes(color)

    button_classes(base, is_syncing, disabled_classes, active_classes)
  end

  # Map color names to actual Tailwind classes to avoid purging issues
  defp color_classes("red"), do: "bg-red-500 hover:bg-red-600 focus:ring-red-500"
  defp color_classes("indigo"), do: "bg-indigo-500 hover:bg-indigo-600 focus:ring-indigo-500"
  defp color_classes("green"), do: "bg-green-500 hover:bg-green-600 focus:ring-green-500"
  defp color_classes("yellow"), do: "bg-yellow-500 hover:bg-yellow-600 focus:ring-yellow-500"
  defp color_classes("blue"), do: "bg-blue-500 hover:bg-blue-600 focus:ring-blue-500"
  defp color_classes("purple"), do: "bg-purple-500 hover:bg-purple-600 focus:ring-purple-500"
  defp color_classes("pink"), do: "bg-pink-500 hover:bg-pink-600 focus:ring-pink-500"
  defp color_classes("gray"), do: "bg-gray-500 hover:bg-gray-600 focus:ring-gray-500"
  # Fallback for unknown colors
  defp color_classes(_), do: "bg-gray-500 hover:bg-gray-600 focus:ring-gray-500"

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
      <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <%= if @config.state do %>
          <rect x="6" y="4" width="4" height="16" rx="1" />
          <rect x="14" y="4" width="4" height="16" rx="1" />
        <% else %>
          <polygon points="5,3 19,12 5,21 5,3" />
        <% end %>
      </svg>
      <span>{@button_text}</span>
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
      <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <path d="M4 4v5h.582M20 20v-5h-.581M5 9A7 7 0 0 1 19 15M19 15V9M5 9v6" />
      </svg>
      <span>{@config.text}</span>
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
