defmodule ReencodarrWeb.ProgressComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="w-full bg-white dark:bg-gray-800 rounded-lg shadow-lg p-4">
      <table class="min-w-full">
        <thead>
          <tr>
            <th class="px-6 py-3 border-b-2 border-gray-300 dark:border-gray-700 text-left leading-4 text-gray-600 dark:text-gray-300 tracking-wider">
              Progress Type
            </th>
            <th class="px-6 py-3 border-b-2 border-gray-300 dark:border-gray-700 text-left leading-4 text-gray-600 dark:text-gray-300 tracking-wider">
              Details
            </th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">Encoding Progress</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <%= if Map.has_key?(@progress, :video) do %>
                <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                  Starting <%= @progress.video.title %>
                </div>
              <% else %>
                <%= if Map.has_key?(@progress, :percent) do %>
                  <ul class="list-disc pl-5 text-sm leading-5 text-gray-900 dark:text-gray-100 fancy-list">
                    <li>
                      <%= Integer.parse(to_string(@progress.percent)) |> elem(0) %> % @ <%= @progress.fps %> fps
                    </li>
                    <li>ETA: <%= @progress.human_readable_eta %></li>
                  </ul>
                  <div class="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2.5 mt-2">
                    <div
                      class="bg-blue-600 h-2.5 rounded-full"
                      style={"width: #{Integer.parse(to_string(@progress.percent)) |> elem(0)}%"}
                    >
                    </div>
                  </div>
                <% else %>
                  <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                    No encoding in progress
                  </div>
                <% end %>
              <% end %>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <div class="text-sm leading-5 text-gray-800 dark:text-gray-200">
                CRF Search Progress
              </div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300 dark:border-gray-700">
              <%= if Map.has_key?(@crf_progress, :percent) do %>
                <ul class="list-disc pl-5 text-sm leading-5 text-gray-900 dark:text-gray-100 fancy-list">
                  <li>CRF: <%= @crf_progress.crf %></li>
                  <li>
                    Percent: <%= Integer.parse(to_string(@crf_progress.percent)) |> elem(0) %> % (of original size)
                  </li>
                  <li>
                    VMAF Score: <%= @crf_progress.score %> (Target: <%= @crf_progress.target_vmaf %>)
                  </li>
                </ul>
              <% else %>
                <div class="text-sm leading-5 text-gray-900 dark:text-gray-100">
                  No CRF search in progress
                </div>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def get_lowest_chosen_vmaf_by_time(videos) do
    videos
    |> Enum.filter(fn video -> !video.reencoded end)
    |> Enum.min_by(& &1.chosen_vmaf, fn -> nil end)
  end
end
