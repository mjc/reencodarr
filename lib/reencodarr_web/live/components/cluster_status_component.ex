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
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
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

          <div class="bg-gray-800 rounded p-4">
            <h3 class="text-lg font-semibold text-white mb-2">Healthy Nodes</h3>
            <p class="text-3xl font-bold text-emerald-400">
              <%= count_healthy_nodes(@cluster_info) %>/<%= length(@cluster_info.cluster_nodes) %>
            </p>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table-auto w-full border-collapse border border-gray-700">
            <thead>
              <tr>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Node</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Status</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Health</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Capabilities</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Type</th>
                <th class="border border-gray-700 px-4 py-2 text-indigo-500">Metrics</th>
              </tr>
            </thead>
            <tbody>
              <%= for node <- @cluster_info.cluster_nodes do %>
                <% health = get_node_health(@cluster_info, node) %>
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
                  <td class="border border-gray-700 px-4 py-2">
                    <%= render_health_status(health) %>
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
                  <td class="border border-gray-700 px-4 py-2 text-gray-300 text-sm">
                    <%= render_node_metrics(health) %>
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

  # Helper functions

  defp count_healthy_nodes(%{health_info: health_info}) when is_map(health_info) do
    health_info
    |> Enum.count(fn {_node, health} ->
      Map.get(health, :status) == :healthy
    end)
  end
  defp count_healthy_nodes(_), do: "N/A"

  defp get_node_health(%{health_info: health_info}, node) when is_map(health_info) do
    Map.get(health_info, node, %{status: :unknown})
  end
  defp get_node_health(_, _), do: %{status: :unknown}

  defp render_health_status(%{status: :healthy, response_time: response_time}) do
    Phoenix.HTML.raw("""
    <div class="flex items-center">
      <span class="px-2 py-1 bg-green-600 text-white text-xs rounded mr-2">HEALTHY</span>
      <span class="text-xs text-gray-400">#{response_time}ms</span>
    </div>
    """)
  end

  defp render_health_status(%{status: :unreachable}) do
    Phoenix.HTML.raw("""
    <span class="px-2 py-1 bg-red-600 text-white text-xs rounded">UNREACHABLE</span>
    """)
  end

  defp render_health_status(%{status: :error, error: error}) do
    Phoenix.HTML.raw("""
    <span class="px-2 py-1 bg-orange-600 text-white text-xs rounded" title="#{error}">ERROR</span>
    """)
  end

  defp render_health_status(_) do
    Phoenix.HTML.raw("""
    <span class="px-2 py-1 bg-gray-600 text-white text-xs rounded">UNKNOWN</span>
    """)
  end

  defp render_node_metrics(%{metrics: %{system: system}}) when is_map(system) do
    cpu = format_cpu(system[:cpu_utilization])
    memory = system[:memory_usage_percent]
    processes = system[:process_count]
    uptime = format_uptime(system[:uptime_seconds])

    Phoenix.HTML.raw("""
    <div class="space-y-1">
      <div>CPU: #{cpu}</div>
      <div>Memory: #{memory}%</div>
      <div>Processes: #{processes}</div>
      <div>Uptime: #{uptime}</div>
    </div>
    """)
  end

  defp render_node_metrics(_) do
    Phoenix.HTML.raw("""
    <span class="text-gray-500">No metrics</span>
    """)
  end

  defp format_cpu(nil), do: "N/A"
  defp format_cpu(cpu) when is_list(cpu) do
    # Get average CPU usage from detailed utilization
    case Enum.find(cpu, fn {key, _} -> key == :total end) do
      {:total, total} -> "#{total}%"
      _ -> "N/A"
    end
  end
  defp format_cpu(cpu), do: "#{cpu}%"

  defp format_uptime(nil), do: "N/A"
  defp format_uptime(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end
  defp format_uptime(_), do: "N/A"
end
