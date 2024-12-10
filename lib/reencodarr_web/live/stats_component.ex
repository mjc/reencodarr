defmodule ReencodarrWeb.StatsComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="w-full bg-white dark:bg-gray-800 rounded-lg shadow-lg p-4">
      <table class="min-w-full">
        <thead>
          <tr>
            <th class="px-6 py-3 border-b-2 border-gray-300 dark:border-gray-700 text-left leading-4 text-gray-600 dark:text-gray-300 tracking-wider">
              Statistic
            </th>
            <th class="px-6 py-3 border-b-2 border-gray-300 dark:border-gray-700 text-left leading-4 text-gray-600 dark:text-gray-300 tracking-wider">
              Value
            </th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">Not Reencoded</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                {@stats.not_reencoded}
              </div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">Reencoded</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                {@stats.reencoded}
              </div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">Total Videos</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                {@stats.total_videos}
              </div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">
                Average VMAF Percentage
              </div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                {@stats.avg_vmaf_percentage}
              </div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">
                Lowest Chosen VMAF Percentage
              </div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                {@stats.lowest_vmaf.percent}
              </div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">Total VMAFs</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                {@stats.total_vmafs}
              </div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">
                Chosen VMAFs Count
              </div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                {@stats.chosen_vmafs_count}
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
