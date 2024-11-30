defmodule ReencodarrWeb.QueueComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="w-full bg-white rounded-lg shadow-lg p-4">
      <table class="min-w-full">
        <thead>
          <tr>
            <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Queue Type</th>
            <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Count</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">CRF Searches in Queue</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @queue_length.crf_searches %></div>
            </td>
          </tr>
          <tr>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-800">Encodes in Queue</div>
            </td>
            <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
              <div class="text-sm leading-5 text-gray-900"><%= @queue_length.encodes %></div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
