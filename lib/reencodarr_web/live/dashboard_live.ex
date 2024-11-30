defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.Media
  import Phoenix.LiveComponent
  alias ReencodarrWeb.VmafTableComponent

  def mount(_params, _session, socket) do
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("crf_search_result")
    counts = Media.count_videos_by_reencoded()
    stats = Media.fetch_additional_stats()
    {:ok, stream(socket, :vmafs, fetch_vmafs()) |> assign(:counts, counts) |> assign(:stats, stats)}
  end

  def handle_info(%{event: "crf_search_result"}, socket) do
    counts = Media.count_videos_by_reencoded()
    stats = Media.fetch_additional_stats()
    {:noreply, stream(socket, :vmafs, fetch_vmafs()) |> assign(:counts, counts) |> assign(:stats, stats)}
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
              <span class="text-lg font-semibold text-gray-900"><%= @counts[false] || 0 %></span>
            </div>
            <div class="flex justify-between items-center">
              <span class="text-lg font-medium text-gray-700">Reencoded:</span>
              <span class="text-lg font-semibold text-gray-900"><%= @counts[true] || 0 %></span>
            </div>
            <div class="flex justify-between items-center">
              <span class="text-lg font-medium text-gray-700">Total Videos:</span>
              <span class="text-lg font-semibold text-gray-900"><%= @stats.total_videos %></span>
            </div>
            <div class="flex justify-between items-center">
              <span class="text-lg font-medium text-gray-700">Average VMAF Percentage:</span>
              <span class="text-lg font-semibold text-gray-900"><%= @stats.avg_vmaf_percentage %></span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp fetch_vmafs do
    Media.list_chosen_vmafs()
  end
end
