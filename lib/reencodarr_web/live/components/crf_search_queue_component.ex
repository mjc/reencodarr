defmodule ReencodarrWeb.CrfSearchQueueComponent do
  use Phoenix.LiveComponent

  import ReencodarrWeb.UIHelpers

  @moduledoc "Displays the CRF search queue."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        Quality Analyzer Queue
      </h2>
      <table class="table-auto w-full border-collapse border border-gray-700">
        <thead>
          <tr>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">File Name</th>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">Bitrate</th>
            <th class="border border-gray-700 px-4 py-2 text-indigo-500">Size</th>
          </tr>
        </thead>
        <tbody>
          <%= for file <- @files do %>
            <tr class={table_row_hover_classes()}>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {format_name(file)}
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {Float.round(file.bitrate / 1_000_000, 2)} Mbit/s
              </td>
              <td class="border border-gray-700 px-4 py-2 text-gray-300">
                {Reencodarr.Formatters.file_size_gib(file.size)} GiB
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
