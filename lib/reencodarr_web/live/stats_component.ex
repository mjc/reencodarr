defmodule ReencodarrWeb.StatsComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="w-3/4">
      <table class="min-w-full bg-white rounded-lg shadow-lg">
        <thead>
          <tr>
            <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Statistic</th>
            <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Value</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">Not Reencoded</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @stats[false] || 0 %></div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">Reencoded</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @stats[true] || 0 %></div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">Total Videos</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @stats.total_videos %></div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">Average VMAF Percentage</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @stats.avg_vmaf_percentage %></div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">Lowest Chosen VMAF Percentage</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @lowest_vmaf.percent %></div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">Total VMAFs</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @stats.total_vmafs %></div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
