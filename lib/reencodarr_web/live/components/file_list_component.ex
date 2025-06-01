defmodule ReencodarrWeb.QueueListComponent do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        {@title}
      </h2>
      <table class="table-auto w-full border-collapse border border-gray-700">
        <thead>
          <tr>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">File Name</th>
            <%= if Enum.any?(@files, &Map.has_key?(&1, :bitrate)) do %>
              <th class="border border-gray-700 px-4 py-2 text-indigo-500">Bitrate (Mbit/s)</th>
            <% end %>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">Size</th>
            <%= if Enum.any?(@files, &Map.has_key?(&1, :percent)) do %>
              <th class="border border-gray-700 px-4 py-2 text-indigo-500">Percent</th>
            <% end %>
          </tr>
        </thead>
        <tbody>
          <%= for file <- @files do %>
            <tr class="hover:bg-gray-800 transition-colors duration-200">
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {if Map.has_key?(file, :video),
                  do: Path.basename(file.video.path),
                  else: Path.basename(file.path)}
              </td>
              <%= if Map.has_key?(file, :bitrate) do %>
                <td class="border border-gray-700 px-4 py-2 text-gray-300">
                  {Float.round(file.bitrate / 1_000_000, 2)} Mbit/s
                </td>
              <% end %>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {if is_integer(file.size),
                  do: "#{Float.round(file.size / 1024 / 1024, 2)} MiB",
                  else: file.size || "N/A"}
              </td>
              <%= if Map.has_key?(file, :percent) do %>
                <td class="border border-gray-700 px-4 py-2 text-gray-300">
                  {file.percent}%
                </td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
