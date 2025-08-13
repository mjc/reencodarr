defmodule ReencodarrWeb.StatisticsComponent do
  @moduledoc """
  Optimized statistics display component - converted to function component for better performance.
  Since this only displays static data, LiveComponent overhead is unnecessary.
  """
  use Phoenix.Component
  alias ReencodarrWeb.Utils.TimeUtils

  require Logger

  attr :stats, :map, required: true
  attr :timezone, :string, required: true

  def statistics(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        Statistics
      </h2>
      <div class="flex flex-col space-y-4">
        <div class="flex items-center justify-between group">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
            <span>Most Recent Video Update</span>
            <span
              class="ml-1 text-xs text-gray-400 group-hover:underline cursor-help"
              title="Last time any video was updated in the database."
            >
              ?
            </span>
          </div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {human_readable_time(@stats.most_recent_video_update, @timezone)}
          </div>
        </div>
        <div class="flex items-center justify-between group">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
            <span>Most Recent Inserted Video</span>
            <span
              class="ml-1 text-xs text-gray-400 group-hover:underline cursor-help"
              title="Last time a new video was added."
            >
              ?
            </span>
          </div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {human_readable_time(@stats.most_recent_inserted_video, @timezone)}
          </div>
        </div>
        <div class="flex items-center justify-between">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">Total VMAFs</div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {@stats.total_vmafs}
          </div>
        </div>
        <div class="flex items-center justify-between">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300">Chosen VMAFs Count</div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {@stats.chosen_vmafs_count}
          </div>
        </div>
        <div class="flex items-center justify-between group">
          <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
            <span>Lowest Chosen VMAF %</span>
            <span
              class="ml-1 text-xs text-gray-400 group-hover:underline cursor-help"
              title="Lowest VMAF percentage chosen for any video."
            >
              ?
            </span>
          </div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200">
            {@stats.lowest_vmaf_percent || "N/A"}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp human_readable_time(nil, _timezone), do: "N/A"

  defp human_readable_time(datetime, timezone) do
    TimeUtils.relative_time_with_timezone(datetime, timezone)
  end
end
