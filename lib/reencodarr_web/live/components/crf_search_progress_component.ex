defmodule ReencodarrWeb.CrfSearchProgressComponent do
  use Phoenix.LiveComponent
  alias Reencodarr.Statistics.CrfSearchProgress

  attr :crf_search_progress, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if CrfSearchProgress.has_data?(@crf_search_progress) do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">
            {CrfSearchProgress.display_filename(@crf_search_progress)}
          </span>
        </div>
        <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
          <ul class="list-disc pl-5 fancy-list">
            <%= if CrfSearchProgress.has_crf?(@crf_search_progress) do %>
              <li>CRF: <strong>{format_number(@crf_search_progress.crf)}</strong></li>
            <% end %>
            <%= if CrfSearchProgress.has_score?(@crf_search_progress) do %>
              <li>
                VMAF Score: <strong>{format_number(@crf_search_progress.score)}</strong>
                <span class="text-gray-500">(Target: 95)</span>
              </li>
            <% end %>
            <%= if CrfSearchProgress.has_percent?(@crf_search_progress) do %>
              <li>Progress: <strong>{format_percent(@crf_search_progress.percent)}</strong></li>
            <% end %>
            <%= if CrfSearchProgress.has_fps?(@crf_search_progress) do %>
              <li>FPS: <strong>{format_number(@crf_search_progress.fps)}</strong></li>
            <% end %>
            <%= if CrfSearchProgress.has_eta?(@crf_search_progress) do %>
              <li>ETA: <strong>{@crf_search_progress.eta}</strong></li>
            <% end %>
          </ul>
        </div>
        <%= if CrfSearchProgress.has_percent?(@crf_search_progress) do %>
          <div class="flex items-center space-x-2">
            <div class="w-full bg-gray-600 rounded-full h-2.5 dark:bg-gray-500">
              <div
                class="bg-purple-600 h-2.5 rounded-full transition-all duration-300"
                style={"width: #{if @crf_search_progress.percent > 0, do: @crf_search_progress.percent, else: 0}%"}
              >
              </div>
            </div>
            <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
              <strong>{format_percent(@crf_search_progress.percent)}</strong>
            </div>
          </div>
        <% end %>
      <% else %>
        <div class="text-sm leading-5 text-gray-400 dark:text-gray-300">
          No CRF search in progress
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions for better formatting
  defp format_number(nil), do: "N/A"
  defp format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 2)
  defp format_number(num) when is_integer(num), do: Integer.to_string(num)
  defp format_number(num), do: to_string(num)

  defp format_percent(nil), do: "N/A"

  defp format_percent(percent) when is_number(percent) do
    "#{format_number(percent)}%"
  end

  defp format_percent(percent), do: "#{percent}%"
end
