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
      "encoding_progress" -> update_progress(socket, msg)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start_encode", %{"vmaf_id" => vmaf_id}, socket) do
    vmaf = Media.get_vmaf!(vmaf_id)
    AbAv1.encode(vmaf)
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
      <div class="bg-white p-8 rounded-lg shadow-lg w-3/4">
        <h2 class="text-2xl font-semibold text-gray-800 mb-4">Statistics</h2>
        <div class="bg-gray-200 p-6 rounded-lg shadow-md space-y-4">
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Not Reencoded:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @stats[false] || 0 %></span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Reencoded:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @stats[true] || 0 %></span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Total Videos:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @stats.total_videos %></span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Average VMAF Percentage:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @stats.avg_vmaf_percentage %></span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Lowest Chosen VMAF Percentage:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @lowest_vmaf.percent %></span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Total VMAFs:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @stats.total_vmafs %></span>
          </div>
        </div>
      </div>

      <div class="bg-white p-8 rounded-lg shadow-lg w-3/4">
        <h2 class="text-2xl font-semibold text-gray-800 mb-4">Queue</h2>
        <div class="bg-gray-200 p-6 rounded-lg shadow-md space-y-4">
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">CRF Searches in Queue:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @queue_length.crf_searches %></span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Encodes in Queue:</span>
            <span class="text-lg font-semibold text-gray-900"><%= @queue_length.encodes %></span>
          </div>
          <div class="flex justify-between items-center">
            <button phx-click="start_encode" phx-value-vmaf_id={@lowest_vmaf.id} class="bg-blue-500 text-white px-4 py-2 rounded">
              Start Encode for Lowest Chosen VMAF
            </button>
          </div>
        </div>
      </div>

      <div class="bg-white p-8 rounded-lg shadow-lg w-3/4">
        <h2 class="text-2xl font-semibold text-gray-800 mb-4">Encoding Progress</h2>
        <div class="bg-gray-200 p-6 rounded-lg shadow-md space-y-4">
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">Encoding Progress:</span>
            <%= if Map.has_key?(@progress, :percent) do %>
              <span class="text-lg font-semibold text-gray-900"><%= @progress.percent %> % @ <%= @progress.fps %> fps, ETA: <%= @progress.eta %> seconds</span>
            <% else %>
              <span class="text-lg font-semibold text-gray-900">No encoding in progress</span>
            <% end %>
          </div>
        </div>
      </div>

      <div class="bg-white p-8 rounded-lg shadow-lg w-3/4">
        <h2 class="text-2xl font-semibold text-gray-800 mb-4">CRF Search Progress</h2>
        <div class="bg-gray-200 p-6 rounded-lg shadow-md space-y-4">
          <div class="flex justify-between items-center">
            <span class="text-lg font-medium text-gray-700">CRF Search Progress:</span>
            <%= if Map.has_key?(@crf_progress, :percent) do %>
              <span class="text-lg font-semibold text-gray-900">CRF: <%= @crf_progress.crf %>, Percent: <%= @crf_progress.percent %> % (of original size), VMAF Score: <%= @crf_progress.score %> (Target: <%= @crf_progress.target_vmaf %>)</span>
            <% else %>
              <span class="text-lg font-semibold text-gray-900">No CRF search in progress</span>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
