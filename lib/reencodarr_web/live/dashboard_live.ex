defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1}
  import Phoenix.LiveComponent

  @update_interval 1_000

  def mount(_params, _session, socket) do
    :timer.send_interval(@update_interval, self(), :update_stats)
    {:ok, assign(socket, update_stats())}
  end

  def handle_info(:update_stats, socket) do
    {:noreply, assign(socket, update_stats())}
  end

  defp update_stats do
    %{
      stats: Media.fetch_stats(),
      queue_length: AbAv1.queue_length(),
      lowest_vmaf: Media.get_lowest_chosen_vmaf() || %Media.Vmaf{},
      lowest_vmaf_by_time: Media.get_lowest_chosen_vmaf_by_time() || %Media.Vmaf{},
      progress: %{},
      crf_progress: %{}
    }
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

  defp start_encode(vmaf_id) do
    vmaf = Media.get_vmaf!(vmaf_id)
    AbAv1.encode(vmaf, :insert_at_top)
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 dark:bg-gray-900 flex flex-col items-center justify-center space-y-8">
      <div class="w-full flex justify-between items-center mb-4 px-4">
        <button
          phx-click="start_encode"
          phx-value-vmaf_id={@lowest_vmaf.id}
          class="bg-blue-500 text-white px-4 py-2 rounded shadow"
        >
          Queue Encode Manually
        </button>
        <button
          phx-click="start_encode_by_time"
          phx-value-vmaf_id={@lowest_vmaf_by_time.id}
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
          lowest_vmaf={@lowest_vmaf}
        />
      </div>
    </div>
    """
  end
end
