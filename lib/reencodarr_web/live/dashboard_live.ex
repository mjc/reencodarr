defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1}
  import Phoenix.LiveComponent

  require Logger

  @update_interval 1_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "progress")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
    end

    encoder_running = Reencodarr.Encoder.running?()
    crf_searcher_running = Reencodarr.CrfSearcher.running?()

    :timer.send_interval(@update_interval, self(), :update_stats)

    {:ok,
     socket
     |> assign(update_stats())
     |> assign(%{timezone: "UTC", vmaf: %Media.Vmaf{}, progress: %{}})
     |> assign(:encoding, encoder_running)
     |> assign(:crf_searching, crf_searcher_running)}
  end

  def handle_info(:update_stats, socket) do
    {:noreply, assign(socket, update_stats())}
  end

  def handle_info({:progress, vmaf}, socket) do
    Logger.debug("Received progress event for VMAF: #{inspect(vmaf)}")
    {:noreply, assign(socket, :vmaf, vmaf)}
  end

  def handle_info({:encoder, :started}, socket) do
    Logger.info("Encoder started")
    {:noreply, assign(socket, :encoding, true)}
  end

  def handle_info({:encoder, :paused}, socket) do
    Logger.info("Encoder paused")
    {:noreply, assign(socket, :encoding, false)}
  end

  def handle_info({:crf_searcher, :started}, socket) do
    Logger.info("CRF search started")
    {:noreply, assign(socket, :crf_searching, true)}
  end

  def handle_info({:crf_searcher, :paused}, socket) do
    Logger.info("CRF search paused")
    {:noreply, assign(socket, :crf_searching, false)}
  end

  def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
    Logger.debug("Setting timezone to #{timezone}")
    {:noreply, assign(socket, :timezone, timezone)}
  end

  def handle_event("start_encode", %{"vmaf_id" => vmaf_id}, socket) do
    start_encode(vmaf_id)
    {:noreply, socket}
  end

  def handle_event("start_encode_by_time", %{"vmaf_id" => vmaf_id}, socket) do
    start_encode(vmaf_id)
    {:noreply, socket}
  end

  def handle_event("queue_next_5_lowest_vmafs", _params, socket) do
    Media.list_chosen_vmafs()
    |> Enum.take(5)
    |> Enum.each(&AbAv1.encode(&1, :insert_at_top))

    {:noreply, socket}
  end

  def handle_event("toggle_encoder", _params, socket) do
    case socket.assigns[:encoding] do
      true ->
        Reencodarr.Encoder.pause()
        Logger.info("Encoder paused")
        {:noreply, assign(socket, :encoding, false)}

      false ->
        Reencodarr.Encoder.start()
        Logger.info("Encoder started")
        {:noreply, assign(socket, :encoding, true)}
    end
  end

  def handle_event("toggle_crf_search", _params, socket) do
    case socket.assigns[:crf_searching] do
      true ->
        Reencodarr.CrfSearcher.pause()
        Logger.info("CRF search paused")
        {:noreply, assign(socket, :crf_searching, false)}

      false ->
        Reencodarr.CrfSearcher.start()
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

  defp start_encode(vmaf_id) do
    vmaf = Media.get_vmaf!(vmaf_id)
    AbAv1.encode(vmaf, :insert_at_top)
  end

  def render(assigns) do
    ~H"""
    <div
      id="dashboard-live"
      class="min-h-screen bg-gray-100 dark:bg-gray-900 flex flex-col items-center justify-center space-y-8"
      phx-hook="TimezoneHook"
    >
      <div class="w-full flex justify-between items-center mb-4 px-4">
        <button
          phx-click="toggle_encoder"
          class={"text-white px-4 py-2 rounded shadow " <> if @encoding, do: "bg-red-500", else: "bg-blue-500"}
        >
          {@encoding && "Pause Encoder" || "Start Encoder"}
        </button>
        <button
          phx-click="toggle_crf_search"
          class={"text-white px-4 py-2 rounded shadow " <> if @crf_searching, do: "bg-red-500", else: "bg-green-500"}
        >
          {@crf_searching && "Pause CRF Search" || "Start CRF Search"}
        </button>
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
