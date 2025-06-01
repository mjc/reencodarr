defmodule ReencodarrWeb.EncodingProgressComponent do
  use Phoenix.LiveComponent

  attr :encoding_progress, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @encoding_progress.filename != :none do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">Encoding:</span>
          <span class="font-mono">{format_name(@encoding_progress.filename)}</span>
          - {parse_integer(@encoding_progress.percent)}%
        </div>
        <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
          <ul class="list-disc pl-5 fancy-list">
            <li>FPS: <strong>{@encoding_progress.fps}</strong></li>
            <li>ETA: <strong>{@encoding_progress.eta}</strong></li>
          </ul>
        </div>
        <div class="flex items-center space-x-2">
          <div class="w-full bg-gray-600 rounded-full h-2.5 dark:bg-gray-500">
            <div
              class="bg-indigo-600 h-2.5 rounded-full transition-all duration-300"
              style="width: #{if parse_integer(@encoding_progress.percent) > 0, do: parse_integer(@encoding_progress.percent), else: 0}%"
            >
            </div>
          </div>
          <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
            <strong>{parse_integer(@encoding_progress.percent)}%</strong>
          </div>
        </div>
      <% else %>
        <div class="text-sm leading-5 text-gray-400 dark:text-gray-300">
          No encoding in progress
        </div>
      <% end %>
    </div>
    """
  end

  defp format_name(path) do
    path = Path.basename(path)

    case Regex.run(~r/^(.+?) - (S\d+E\d+)/, path) do
      [_, series_name, episode_name] -> "#{series_name} - #{episode_name}"
      [_, movie_name] -> movie_name
      _ -> path
    end
  end

  defp parse_integer(value), do: Integer.parse(to_string(value)) |> elem(0)
end
