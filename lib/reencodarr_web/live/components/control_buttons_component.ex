defmodule ReencodarrWeb.ControlButtonsComponent do
  @moduledoc """
  Modern control buttons component for managing system operations.

  Provides interactive controls for:
  - Broadway pipelines (analyzer, CRF searcher, encoder)
  - Sync services (Sonarr, Radarr)
  - Visual feedback and state management
  """

  use Phoenix.LiveComponent
  require Logger

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-3" role="group" aria-label="System control operations">
      <.pipeline_controls
        encoding={@encoding}
        crf_searching={@crf_searching}
        analyzing={@analyzing}
        myself={@myself}
      />
      <.sync_controls syncing={@syncing} myself={@myself} />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_analyzer", _params, socket) do
    toggle_service(:analyzer)
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_crf_search", _params, socket) do
    toggle_service(:crf_search)
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_encoder", _params, socket) do
    toggle_service(:encoder)
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("sync_episodes", _params, socket) do
    Logger.info("Starting episode sync")
    Reencodarr.Sync.sync_episodes()
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("sync_movies", _params, socket) do
    Logger.info("Starting movie sync")
    Reencodarr.Sync.sync_movies()
    {:noreply, socket}
  end

  # Service toggle logic
  defp toggle_service(:analyzer) do
    case analyzer_running?() do
      true -> Reencodarr.Analyzer.Broadway.pause()
      false -> Reencodarr.Analyzer.Broadway.resume()
    end
  end

  defp toggle_service(:crf_search) do
    case crf_search_running?() do
      true -> Reencodarr.CrfSearcher.Broadway.pause()
      false -> Reencodarr.CrfSearcher.Broadway.resume()
    end
  end

  defp toggle_service(:encoder) do
    case encoder_running?() do
      true -> Reencodarr.Encoder.Broadway.pause()
      false -> Reencodarr.Encoder.Broadway.resume()
    end
  end

  # Service status helpers
  defp analyzer_running?, do: Reencodarr.Analyzer.Broadway.Producer.running?()
  defp crf_search_running?, do: Reencodarr.CrfSearcher.Broadway.Producer.running?()
  defp encoder_running?, do: Reencodarr.Encoder.Broadway.Producer.running?()

  # Pipeline controls section
  defp pipeline_controls(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
      <.control_button
        id="analyzer-toggle"
        label={if @analyzing, do: "PAUSE ANALYZER", else: "RESUME ANALYZER"}
        event="toggle_analyzer"
        myself={@myself}
        active={@analyzing}
        icon={if @analyzing, do: "⏸️", else: "▶️"}
        color={if @analyzing, do: "yellow", else: "green"}
      />

      <.control_button
        id="crf-search-toggle"
        label={if @crf_searching, do: "PAUSE CRF SEARCH", else: "RESUME CRF SEARCH"}
        event="toggle_crf_search"
        myself={@myself}
        active={@crf_searching}
        icon={if @crf_searching, do: "⏸️", else: "🔍"}
        color={if @crf_searching, do: "yellow", else: "blue"}
      />

      <.control_button
        id="encoder-toggle"
        label={if @encoding, do: "PAUSE ENCODER", else: "RESUME ENCODER"}
        event="toggle_encoder"
        myself={@myself}
        active={@encoding}
        icon={if @encoding, do: "⏸️", else: "⚡"}
        color={if @encoding, do: "yellow", else: "red"}
      />
    </div>
    """
  end

  # Sync controls section
  defp sync_controls(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
      <.control_button
        id="sync-episodes"
        label="SYNC EPISODES"
        event="sync_episodes"
        myself={@myself}
        active={false}
        disabled={@syncing}
        icon="📺"
        color="orange"
      />

      <.control_button
        id="sync-movies"
        label="SYNC MOVIES"
        event="sync_movies"
        myself={@myself}
        active={false}
        disabled={@syncing}
        icon="🎬"
        color="purple"
      />
    </div>
    """
  end

  # Modern control button component
  defp control_button(assigns) do
    disabled = Map.get(assigns, :disabled, false)

    assigns = assign(assigns, :disabled, disabled)

    ~H"""
    <button
      id={@id}
      phx-click={@event}
      phx-target={@myself}
      disabled={@disabled}
      aria-label={@label}
      class={[
        "h-10 px-3 font-bold text-xs tracking-wider rounded transition-all duration-200 flex items-center justify-center space-x-2",
        "hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-900",
        button_color_classes(@color, @active, @disabled)
      ]}
    >
      <span>{@icon}</span>
      <span>{@label}</span>
    </button>
    """
  end

  # Color helper for buttons
  defp button_color_classes(color, active, disabled) do
    cond do
      disabled -> disabled_button_classes()
      active -> active_button_classes()
      true -> normal_button_classes(color)
    end
  end

  defp disabled_button_classes do
    "bg-gray-600 text-gray-400 cursor-not-allowed opacity-50"
  end

  defp active_button_classes do
    "bg-yellow-500 text-yellow-900 focus:ring-yellow-400"
  end

  defp normal_button_classes(color) do
    case color do
      "green" -> "bg-green-500 hover:bg-green-400 text-black focus:ring-green-400"
      "blue" -> "bg-blue-500 hover:bg-blue-400 text-white focus:ring-blue-400"
      "red" -> "bg-red-500 hover:bg-red-400 text-black focus:ring-red-400"
      "orange" -> "bg-orange-500 hover:bg-orange-400 text-black focus:ring-orange-400"
      "purple" -> "bg-purple-500 hover:bg-purple-400 text-white focus:ring-purple-400"
      "yellow" -> "bg-yellow-500 hover:bg-yellow-400 text-yellow-900 focus:ring-yellow-400"
      _ -> "bg-gray-500 hover:bg-gray-400 text-white focus:ring-gray-400"
    end
  end
end
