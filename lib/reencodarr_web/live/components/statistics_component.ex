defmodule ReencodarrWeb.StatisticsComponent do
  use Phoenix.LiveComponent

  require Logger

  attr :stats, :map, required: true
  attr :timezone, :string, required: true

  # Document PubSub topics related to statistics updates
  @doc "Handles statistics updates broadcasted via PubSub"

  @impl true
  def render(assigns) do
    if is_map(assigns.stats) and is_binary(assigns.timezone) do
      ~H"""
      <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
        <h2 class="text-lg font-bold mb-4 text-pink-300 flex items-center space-x-2">
          <svg
            class="w-5 h-5 text-pink-400"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <circle cx="12" cy="12" r="10"></circle>
          </svg>
          <span>Statistics</span>
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
              {@stats.lowest_vmaf.percent}
            </div>
          </div>
        </div>
      </div>
      """
    else
      Logger.error("Invalid statistics or timezone received: #{inspect(assigns)}")

      ~H"""
      <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
        <h2 class="text-lg font-bold mb-4 text-red-500">Error: Invalid Statistics</h2>
      </div>
      """
    end
  end

  defp human_readable_time(nil, _timezone), do: "N/A"

  defp human_readable_time(datetime, timezone) do
    tz = if is_binary(timezone) and timezone != "", do: timezone, else: "UTC"

    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.shift_zone!(tz)
    |> relative_time()
  end

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff} second(s) ago"
      diff < 3600 -> "#{div(diff, 60)} minute(s) ago"
      diff < 86400 -> "#{div(diff, 3600)} hour(s) ago"
      true -> "#{div(diff, 86400)} day(s) ago"
    end
  end
end
