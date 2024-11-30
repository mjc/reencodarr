defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.Media
  import Phoenix.LiveComponent
  alias ReencodarrWeb.VmafTableComponent

  def mount(_params, _session, socket) do
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("crf_search_result")
    counts = Media.count_videos_by_reencoded()
    {:ok, stream(socket, :vmafs, fetch_vmafs()) |> assign(:counts, counts)}
  end

  def handle_info(%{event: "crf_search_result"}, socket) do
    counts = Media.count_videos_by_reencoded()
    {:noreply, stream(socket, :vmafs, fetch_vmafs()) |> assign(:counts, counts)}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 flex items-center justify-center">
      <div class="bg-white p-8 rounded-lg shadow-lg flex">
        <div class="w-3/4">
          <h1 class="text-2xl font-bold text-gray-900 mb-4">Welcome to the Dashboard</h1>
          <div id="vmaf-data" class="w-full max-w-4xl">
            <.live_component module={VmafTableComponent} id="vmaf-table" vmafs={@streams.vmafs} />
          </div>
        </div>
        <div class="w-1/4 ml-8">
          <h2 class="text-xl font-semibold text-gray-800 mb-2">Statistics</h2>
          <div class="bg-gray-200 p-4 rounded-lg shadow-md">
            <p class="text-lg">Not Reencoded: <%= @counts[false] || 0 %></p>
            <p class="text-lg">Reencoded: <%= @counts[true] || 0 %></p>
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
