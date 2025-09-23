defmodule ReencodarrWeb.EncodeQueueComponent do
  use Phoenix.LiveComponent

  import ReencodarrWeb.UIHelpers

  @moduledoc "Displays the encoding queue."

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
            <tr class={table_row_hover_classes()}>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {format_name(file.video)}
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {Reencodarr.Formatters.file_size_gib(file.video.size)} GiB
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {Reencodarr.Formatters.potential_savings_gib(file.video.size, file.predicted_filesize)} GiB
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {Reencodarr.Formatters.savings_percentage(file.video.size, file.predicted_filesize)}%
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_name(%{path: path}) do
    Reencodarr.Formatters.filename(path)
  end
end
