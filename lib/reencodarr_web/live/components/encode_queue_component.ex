defmodule ReencodarrWeb.EncodeQueueComponent do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        Encoding Queue
      </h2>
      <table class="table-auto w-full border-collapse border border-gray-700">
        <thead>
          <tr>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">File Name</th>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">Size</th>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">Savings</th>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">Percent</th>
          </tr>
        </thead>
        <tbody>
          <%= for file <- @files do %>
            <tr class="hover:bg-gray-800 transition-colors duration-200">
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {format_name(file.video)}
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {file.size}
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {calculate_savings(file)} GiB
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {file.percent}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp calculate_savings(file) do
    savings = file.video.size - file.video.size * (file.percent / 100)
    (savings / 1_073_741_824) |> Float.round(2)
  end

  defp format_name(%{path: path}) do
    path = Path.basename(path)

    case Regex.run(~r/^(.+?) - (S\d+E\d+)/, path) do
      [_, series_name, episode_name] -> "#{series_name} - #{episode_name}"
      [_, movie_name] -> movie_name
      _ -> path
    end
  end
end
