defmodule ReencodarrWeb.ClusterStatusComponent do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        Cluster Status
      </h2>

      <%= if @cluster_info do %>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
          <div class="bg-gray-800 rounded p-4">
            <h3 class="text-lg font-semibold text-white mb-2">Total Nodes</h3>
            <p class="text-3xl font-bold text-green-400"><%= length(@cluster_info.cluster_nodes) %></p>
          </div>

          <div class="bg-gray-800 rounded p-4">
            <h3 class="text-lg font-semibold text-white mb-2">CRF Workers</h3>
            <p class="text-3xl font-bold text-blue-400"><%= @cluster_info.ring_sizes.crf_search %></p>
          </div>

          <div class="bg-gray-800 rounded p-4">
            <h3 class="text-lg font-semibold text-white mb-2">Encoders</h3>
            <p class="text-3xl font-bold text-purple-400"><%= @cluster_info.ring_sizes.encode %></p>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table-auto w-full border-collapse border border-gray-700">
            <thead>
              <tr>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Node</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Status</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Capabilities</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Type</th>
              </tr>
            </thead>
            <tbody>
              <%= for node <- @cluster_info.cluster_nodes do %>
                <tr class="hover:bg-gray-800 transition-colors duration-200">
                  <td class="border border-gray-700 px-4 py-2 text-gray-300 font-mono">
                    <%= node %>
                    <%= if node == @cluster_info.local_node do %>
                      <span class="ml-2 px-2 py-1 bg-green-600 text-white text-xs rounded">LOCAL</span>
                    <% end %>
                  </td>
                  <td class="border border-gray-700 px-4 py-2">
                    <span class="px-2 py-1 bg-green-600 text-white text-xs rounded">ONLINE</span>
                  </td>
                  <td class="border border-gray-700 px-4 py-2 text-gray-300">
                    <%= case Map.get(@cluster_info.node_capabilities, node, @cluster_info.local_capabilities) do %>
                      <% capabilities when is_list(capabilities) -> %>
                        <%= Enum.join(capabilities, ", ") %>
                      <% _ -> %>
                        unknown
                    <% end %>
                  </td>
                  <td class="border border-gray-700 px-4 py-2 text-gray-300">
                    <%= if node == @cluster_info.local_node and @has_web_server do %>
                      <span class="px-2 py-1 bg-blue-600 text-white text-xs rounded">SERVER</span>
                    <% else %>
                      <span class="px-2 py-1 bg-gray-600 text-white text-xs rounded">WORKER</span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <div class="text-center py-8">
          <p class="text-gray-400">Single node mode - no cluster information available</p>
          <p class="text-sm text-gray-500 mt-2">
            Start additional worker nodes to see cluster status
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end
end
