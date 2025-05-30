defmodule ReencodarrWeb.QueueListComponent do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        {@title}
      </h2>
      <ul class="divide-y divide-gray-700">
        <%= for file <- @files do %>
          <li class="py-2 hover:bg-gray-800 transition-colors duration-200 rounded-md">
            <span class="text-gray-300 text-sm font-medium">
              {format_file(file)}
            </span>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp format_file(%Reencodarr.Media.Video{path: path}) do
    basename = Path.basename(path)

    case Regex.run(~r/^(?<show_name>.+?) - (?<episode_number>S\d+E\d+)/, basename) do
      [_, show_name, episode_number] -> "#{show_name} - #{episode_number}"
      _ -> basename
    end
  end

  defp format_file(%Reencodarr.Media.Vmaf{
         percent: percent,
         video: %Reencodarr.Media.Video{path: path}
       }) do
    basename = Path.basename(path)

    case Regex.run(~r/^(?<show_name>.+?) - (?<episode_number>S\d+E\d+)/, basename) do
      [_, show_name, episode_number] -> "#{show_name} - #{episode_number} (Percent: #{percent}%)"
      _ -> "#{basename} (Percent: #{percent}%)"
    end
  end

  defp format_file(%Reencodarr.Media.Video{path: path, bitrate: bitrate, size: size}) do
    basename = Path.basename(path)

    case Regex.run(~r/^(?<show_name>.+?) - (?<episode_number>S\d+E\d+)/, basename) do
      [_, show_name, episode_number] ->
        "#{show_name} - #{episode_number} (Bitrate: #{bitrate} kbps, Size: #{size} bytes)"

      _ ->
        "#{basename} (Bitrate: #{bitrate} kbps, Size: #{size} bytes)"
    end
  end

  defp format_file(_), do: "Unknown"
end
