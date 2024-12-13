defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1, Encoder, CrfSearcher}
  import Phoenix.LiveComponent

  require Logger

  @update_interval 1_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "progress")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
    end

    :timer.send_interval(@update_interval, self(), :update_stats)

    socket =
      socket
      |> assign(update_stats())
      |> assign(:timezone, "UTC")
      |> assign(:vmaf, %Media.Vmaf{})
      |> assign(:progress, %{})
      |> assign(:encoding, Encoder.scanning?())
      |> assign(:crf_searching, CrfSearcher.scanning?())

    {:ok, socket}
  end

  def handle_info(:update_stats, socket) do
    {:noreply, assign(socket, update_stats())}
  end

  def handle_info({:progress, vmaf}, socket) do
    Logger.debug("Received progress event for VMAF: #{inspect(vmaf)}")
    {:noreply, assign(socket, :vmaf, vmaf)}
  end

  def handle_info({:encoder, :started}, socket) do
    Logger.debug("Encoder started")
    {:noreply, assign(socket, :encoding, true)}
  end

  def handle_info({:encoder, :paused}, socket) do
    Logger.debug("Encoder paused")
    {:noreply, assign(socket, :encoding, false)}
  end

  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, socket) do
    Logger.debug("Encoding progress: #{percent}% ETA: #{eta} FPS: #{fps}")
    {:noreply, assign(socket, :progress, %{percent: percent, eta: eta, fps: fps})}
  end

  def handle_info({:crf_searcher, :started}, socket) do
    Logger.debug("CRF search started")
    {:noreply, assign(socket, :crf_searching, true)}
  end

  def handle_info({:crf_searcher, :paused}, socket) do
    Logger.debug("CRF search paused")
    {:noreply, assign(socket, :crf_searching, false)}
  end

  def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
    Logger.debug("Setting timezone to #{timezone}")
    {:noreply, assign(socket, :timezone, timezone)}
  end

  def handle_event("toggle_encoder", _params, socket) do
    if socket.assigns.encoding do
      Encoder.pause()
      Logger.info("Encoder paused")
      {:noreply, assign(socket, :encoding, false)}
    else
      Encoder.start()
      Logger.info("Encoder started")
      {:noreply, assign(socket, :encoding, true)}
    end
  end

  def handle_event("toggle_crf_search", _params, socket) do
    if socket.assigns.crf_searching do
      CrfSearcher.pause()
      Logger.info("CRF search paused")
      {:noreply, assign(socket, :crf_searching, false)}
    else
      CrfSearcher.start()
      Logger.info("CRF search started")
      {:noreply, assign(socket, :crf_searching, true)}
    end
  end

  defp update_stats do
    %{
      queue_length: AbAv1.queue_length(),
      stats: Media.fetch_stats()
    }
  end

  def render(assigns) do
    ~H"""
    <div
      id="dashboard-live"
      class="min-h-screen bg-gray-100 dark:bg-gray-900 flex flex-col items-center justify-center space-y-8"
      phx-hook="TimezoneHook"
    >
      <div class="w-full flex justify-between items-center mb-4 px-4">
        <.live_component
          module={ReencodarrWeb.ToggleComponent}
          id="toggle-encoder"
          toggle_event="toggle_encoder"
          active={@encoding}
          active_text="Pause Encoder"
          inactive_text="Start Encoder"
          active_class="bg-red-500"
          inactive_class="bg-blue-500"
        />
        <.live_component
          module={ReencodarrWeb.ToggleComponent}
          id="toggle-crf-search"
          toggle_event="toggle_crf_search"
          active={@crf_searching}
          active_text="Pause CRF Search"
          inactive_text="Start CRF Search"
          active_class="bg-red-500"
          inactive_class="bg-green-500"
        />
      </div>

      <div class="w-full grid grid-cols-1 md:grid-cols-2 gap-4 px-4">
        <.live_component
          module={ReencodarrWeb.QueueComponent}
          id="queue-component"
          queue_length={@queue_length}
        />
        <.live_component
          module={ReencodarrWeb.ProgressComponent}
          id="progress-component"
          progress={@progress}
          vmaf={@vmaf}
        />
        <.live_component
          module={ReencodarrWeb.StatsComponent}
          id="stats-component"
          stats={@stats}
          timezone={@timezone}
        />
      </div>
    </div>
    """
  end
end
