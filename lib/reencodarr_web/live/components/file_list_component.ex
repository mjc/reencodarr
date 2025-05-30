defmodule ReencodarrWeb.QueueListComponent do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg shadow-md p-6">
      <h2 class="text-xl font-bold text-indigo-400 mb-4">
        {@title}
      </h2>
      <ul class="list-disc pl-5 text-gray-300">
        <%= for file <- @files do %>
          <li class="hover:text-indigo-400 transition-colors duration-200">
            {format_file(file)}
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
