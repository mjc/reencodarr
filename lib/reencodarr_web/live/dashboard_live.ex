defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1}
  import Phoenix.LiveComponent

  def mount(_params, _session, socket) do
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("scanning")
    stats = Media.fetch_stats()
    queue_length = AbAv1.queue_length()
    lowest_vmaf = Media.get_lowest_chosen_vmaf()
    {:ok, assign(socket, :stats, stats) |> assign(:queue_length, queue_length) |> assign(:lowest_vmaf, lowest_vmaf) |> assign(:progress, %{}) |> assign(:crf_progress, %{})}
  end

  def handle_info(%{action: action} = msg, socket) do
    case action do
      "scanning:start" -> {:noreply, socket}
      "scanning:finished" -> update_stats(socket)
      "scanning:progress" -> update_crf_progress(socket, msg)
      "queue:update" -> update_queue_length(socket, msg.crf_searches, msg.encodes)
      "encoding:progress" -> update_progress(socket, msg)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start_encode", %{"vmaf_id" => vmaf_id}, socket) do
    vmaf = Media.get_vmaf!(vmaf_id)
    AbAv1.encode(vmaf, :insert_at_top)
    {:noreply, socket}
  end

  defp update_stats(socket) do
    stats = Media.fetch_stats()
    lowest_vmaf = Media.get_lowest_chosen_vmaf()
    {:noreply, assign(socket, :stats, stats) |> assign(:lowest_vmaf, lowest_vmaf)}
  end

  defp update_queue_length(socket, crf_searches, encodes) do
    {:noreply, assign(socket, :queue_length, %{crf_searches: crf_searches, encodes: encodes})}
  end

  defp update_progress(socket, %{video: video, percent: percent, fps: fps, eta: eta}) do
    progress = %{video_id: video.id, percent: percent, fps: fps, eta: eta}
    {:noreply, assign(socket, :progress, progress)}
  end

  defp update_crf_progress(socket, %{vmaf: vmaf}) do
    if Map.has_key?(vmaf, "video_id") do
      crf_progress = %{video_id: vmaf["video_id"], percent: vmaf["percent"], crf: vmaf["crf"], score: vmaf["score"], target_vmaf: vmaf["target_vmaf"]}
      {:noreply, assign(socket, :crf_progress, crf_progress)}
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 flex flex-col items-center justify-center space-y-8">
      <div class="w-3/4 flex justify-between items-center mb-4">
        <button phx-click="start_encode" phx-value-vmaf_id={@lowest_vmaf.id} class="bg-blue-500 text-white px-4 py-2 rounded shadow">
          Queue Encode Manually
        </button>
      </div>

      <.live_component module={ReencodarrWeb.QueueComponent} id="queue-component" queue_length={@queue_length} />
      <.live_component module={ReencodarrWeb.ProgressComponent} id="progress-component" progress={@progress} crf_progress={@crf_progress} />
      <.live_component module={ReencodarrWeb.StatsComponent} id="stats-component" stats={@stats} lowest_vmaf={@lowest_vmaf} />
    </div>
    """
  end
end
