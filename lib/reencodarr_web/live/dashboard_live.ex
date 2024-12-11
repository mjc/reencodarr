defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1}
  import Phoenix.LiveComponent

  require Logger

  @update_interval 1_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "progress")
    end
    :timer.send_interval(@update_interval, self(), :update_stats)
    {:ok, assign(socket, update_stats() |> Map.put(:timezone, "UTC"))}
  end

  def handle_info(:update_stats, socket) do
    {:noreply, assign(socket, update_stats())}
  end

  def handle_info({:progress, vmaf}, socket) do
    Logger.debug("Received progress event for VMAF: #{inspect(vmaf)}")
    {:noreply, assign(socket, :crf_progress, vmaf)}
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

  defp update_stats do
    %{
      crf_progress: %{},
      progress: %{},
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
          phx-click="start_encode"
          phx-value-vmaf_id={@stats.lowest_vmaf.id}
          class="bg-blue-500 text-white px-4 py-2 rounded shadow"
        >
          Queue Encode Manually
        </button>
        <button
          phx-click="start_encode_by_time"
          phx-value-vmaf_id={@stats.lowest_vmaf_by_time.id}
          class="bg-green-500 text-white px-4 py-2 rounded shadow"
        >
          Queue Encode by Time
        </button>
        <button
          phx-click="queue_next_5_lowest_vmafs"
          class="bg-red-500 text-white px-4 py-2 rounded shadow"
        >
          Queue Next 5 Lowest VMAFs
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
          crf_progress={@crf_progress}
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
