defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1}
  import Phoenix.LiveComponent

  def mount(_params, _session, socket) do
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("scanning")
    stats = Media.fetch_stats()
    queue_length = AbAv1.queue_length()
    {:ok, assign(socket, :stats, stats) |> assign(:queue_length, queue_length)}
  end

  def handle_info(%{action: action} = msg, socket) do
    case action do
      "scanning:start" -> {:noreply, socket}
      "scanning:finished" -> update_stats(socket)
      "scanning:progress" -> update_stats(socket)
      "queue:update" -> update_queue_length(socket, msg.crf_searches, msg.encodes)
      _ -> {:noreply, socket}
    end
  end

  defp update_stats(socket) do
    stats = Media.fetch_stats()
    {:noreply, assign(socket, :stats, stats)}
  end

  defp update_queue_length(socket, crf_searches, encodes) do
    {:noreply, assign(socket, :queue_length, %{crf_searches: crf_searches, encodes: encodes})}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 flex items-center justify-center">
      <div class="bg-white p-8 rounded-lg shadow-lg flex w-3/4">
        <div class="w-full ml-8">
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
              <span class="text-lg font-medium text-gray-700">Total VMAFs:</span>
              <span class="text-lg font-semibold text-gray-900"><%= @stats.total_vmafs %></span>
            </div>
            <div class="flex justify-between items-center">
              <span class="text-lg font-medium text-gray-700">CRF Searches in Queue:</span>
              <span class="text-lg font-semibold text-gray-900"><%= @queue_length.crf_searches %></span>
            </div>
            <div class="flex justify-between items-center">
              <span class="text-lg font-medium text-gray-700">Encodes in Queue:</span>
              <span class="text-lg font-semibold text-gray-900"><%= @queue_length.encodes %></span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
