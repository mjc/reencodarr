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
          <%= for {label, value} <- stats_data(@stats, @timezone) do %>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
                <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">{label}</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
                <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">{value}</div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp stats_data(stats, timezone) do
    [
      {"Most Recent Video Update", format_datetime(stats.most_recent_video_update, timezone)},
      {"Most Recent Inserted Video", format_datetime(stats.most_recent_inserted_video, timezone)},
      {"Not Reencoded", stats.not_reencoded},
      {"Reencoded", stats.reencoded},
      {"Total Videos", stats.total_videos},
      {"Average VMAF Percentage", stats.avg_vmaf_percentage},
      {"Lowest Chosen VMAF Percentage", stats.lowest_vmaf.percent},
      {"Total VMAFs", stats.total_vmafs},
      {"Chosen VMAFs Count", stats.chosen_vmafs_count}
    ]
  end

  defp format_datetime(nil, _timezone), do: "N/A"

  defp format_datetime(datetime, timezone) do
    datetime
    |> Timex.to_datetime("Etc/UTC")
    |> Timex.Timezone.convert(timezone)
    |> Timex.format!("{Mshort} {D}, {YYYY} {h12}:{m}:{s} {AM}")
  end
end
