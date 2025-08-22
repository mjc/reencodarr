defmodule ReencodarrWeb.ControlButtonsComponent do
  @moduledoc "Renders the LCARS control buttons for dashboard actions."
  use Phoenix.Component
  use Phoenix.LiveComponent

  require Logger

  @doc "Handles toggle and sync events for LCARS control interface"

  @impl true
  def mount(socket) do
    # Don't initialize state here since it's provided by the parent component
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:encoding, Map.get(assigns, :encoding, false))
      |> assign(:crf_searching, Map.get(assigns, :crf_searching, false))
      |> assign(:analyzing, Map.get(assigns, :analyzing, false))
      |> assign(:syncing, Map.get(assigns, :syncing, false))

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle", %{"target" => target}, socket) do
    case target do
      "encoder" ->
        toggle_app(Reencodarr.Encoder.Broadway, :encoding, socket)

      "crf_search" ->
        toggle_app(Reencodarr.CrfSearcher, :crf_searching, socket)

      "analyzer" ->
        toggle_app(Reencodarr.Analyzer.Broadway, :analyzing, socket)

      _ ->
        Logger.error("Unknown toggle target: #{inspect(target)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("sync", %{"target" => target}, socket) do
    case target do
      "sonarr" ->
        Logger.info("Starting Episodes sync")
        Reencodarr.Sync.sync_episodes()

      "radarr" ->
        Logger.info("Starting Movies sync")
        Reencodarr.Sync.sync_movies()

      _ ->
        Logger.error("Unknown sync target: #{inspect(target)}")
    end

    # Don't update local state - let the global telemetry system handle it
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="h-8 bg-orange-500 lcars-corner-br flex items-center px-4">
        <span class="text-black lcars-label text-sm">CONTROLS</span>
      </div>

      <div class="space-y-1">
        <.lcars_control_button
          label="ENCODER"
          active={@encoding}
          target="encoder"
          type="toggle"
          myself={@myself}
        />
        <.lcars_control_button
          label="CRF SEARCH"
          active={@crf_searching}
          target="crf_search"
          type="toggle"
          myself={@myself}
        />
        <.lcars_control_button
          label="ANALYZER"
          active={@analyzing}
          target="analyzer"
          type="toggle"
          myself={@myself}
        />
        <.lcars_control_button
          label="SYNC EPISODES"
          disabled={@syncing}
          target="sonarr"
          type="sync"
          color="yellow"
          myself={@myself}
        />
        <.lcars_control_button
          label="SYNC MOVIES"
          disabled={@syncing}
          target="radarr"
          type="sync"
          color="green"
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  # Private helper functions

  defp toggle_app(app, type, socket) do
    current_state = Map.get(socket.assigns, type)
    Logger.info("Toggling #{type} - current state: #{current_state}")
    new_state = not current_state

    if new_state do
      Logger.info("Starting #{type}")
      app.start()
    else
      Logger.info("Pausing #{type}")
      app.pause()
    end

    # Don't update local state - let the global telemetry system handle it
    {:noreply, socket}
  end

  defp lcars_control_button(assigns) do
    assigns =
      assigns
      |> assign_new(:active, fn -> false end)
      |> assign_new(:disabled, fn -> false end)
      |> assign_new(:color, fn -> "orange" end)

    ~H"""
    <button
      phx-click={@type}
      phx-target={@myself}
      phx-value-target={@target}
      disabled={@disabled}
      class={[
        "w-full h-8 lcars-corner-br flex items-center px-3 lcars-label text-xs transition-all duration-200 lcars-button",
        "text-black hover:brightness-110 disabled:opacity-50 disabled:cursor-not-allowed",
        lcars_button_color(@type, @active, @disabled, @color)
      ]}
    >
      <div class="flex items-center space-x-2">
        <div class={[
          "w-2 h-2 rounded-full",
          if(@type == "toggle" && @active,
            do: "bg-green-300 lcars-status-online",
            else: "bg-gray-800"
          )
        ]}>
        </div>
        <span>{@label}</span>
      </div>
    </button>
    """
  end

  defp lcars_button_color("toggle", active, _disabled, _color) do
    if active, do: "bg-red-500", else: "bg-blue-500"
  end

  defp lcars_button_color("sync", _active, disabled, color) do
    if disabled do
      "bg-gray-600"
    else
      case color do
        "yellow" -> "bg-yellow-400"
        "green" -> "bg-green-500"
        _ -> "bg-orange-500"
      end
    end
  end
end
