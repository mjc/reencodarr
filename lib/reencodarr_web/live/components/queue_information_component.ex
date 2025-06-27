defmodule ReencodarrWeb.QueueInformationComponent do
  @moduledoc """
  Optimized queue information component - converted to function component for better performance.
  Since this only displays static data, LiveComponent overhead is unnecessary.
  """
  use Phoenix.Component

  require Logger

  attr :stats, :map, required: true

  def queue_information(assigns) do
    if is_map(assigns.stats) do
      ~H"""
      <div class="bg-gray-900 rounded-lg shadow-lg p-6 border border-gray-700">
        <h2 class="text-2xl font-bold text-indigo-500 mb-4">
          Queue Details
        </h2>
        <div class="flex flex-col space-y-4">
          <div class="flex items-center justify-between">
            <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
              <span>CRF Searches in Queue</span>
              <span class="ml-1 text-xs text-gray-400" title="Number of CRF search jobs waiting.">
                ?
              </span>
            </div>
            <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
              {@stats.queue_length.crf_searches}
            </div>
          </div>
          <div class="flex items-center justify-between">
            <div class="text-sm leading-5 text-gray-200 dark:text-gray-300 flex items-center space-x-1">
              <span>Encodes in Queue</span>
              <span class="ml-1 text-xs text-gray-400" title="Number of encoding jobs waiting.">?</span>
            </div>
            <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
              {@stats.queue_length.encodes}
            </div>
          </div>
        </div>
      </div>
      """
    else
      Logger.error("Invalid stats received for queue information: #{inspect(assigns.stats)}")

      ~H"""
      <div class="w-full bg-gray-800/90 rounded-xl shadow-lg p-6 border border-gray-700">
        <h2 class="text-lg font-bold mb-4 text-red-500">Error: Invalid Queue Information</h2>
      </div>
      """
    end
  end
end
