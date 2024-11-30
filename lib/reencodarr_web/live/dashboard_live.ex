defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.Media
  import Phoenix.LiveComponent

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :vmaf_data, fetch_vmaf_data())}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 flex items-center justify-center">
      <div class="bg-white p-8 rounded-lg shadow-lg">
        <h1 class="text-2xl font-bold text-gray-900 mb-4">Welcome to the Dashboard</h1>
        <div id="vmaf-data" class="w-full max-w-4xl">
          <table class="min-w-full bg-white">
            <thead>
              <tr>
                <th class="py-2">Title</th>
                <th class="py-2">Percent</th>
                <th class="py-2">Size</th>
                <th class="py-2">Time</th>
              </tr>
            </thead>
            <tbody>
              <%= for vmaf <- Enum.take(@vmaf_data, 10) do %>
                <tr>
                  <td class="border px-4 py-2"><%= vmaf.video.title %></td>
                  <td class="border px-4 py-2"><%= vmaf.percent %></td>
                  <td class="border px-4 py-2"><%= vmaf.size %></td>
                  <td class="border px-4 py-2"><%= vmaf.time %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp fetch_vmaf_data do
    Media.list_chosen_vmafs()
  end
end
