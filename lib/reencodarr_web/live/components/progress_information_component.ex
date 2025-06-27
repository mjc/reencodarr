defmodule ReencodarrWeb.ProgressInformationComponent do
  @moduledoc """
  Optimized progress information component with inlined displays to reduce LiveComponent nesting.
  Converts from using 3 nested LiveComponents to simple inline functions for better performance.
  """
  use Phoenix.Component

  alias Reencodarr.Statistics.CrfSearchProgress
  alias Reencodarr.ProgressHelpers

  attr :encoding_progress, :map, required: true
  attr :crf_search_progress, :map, required: true
  attr :sync_progress, :integer, required: true

  def progress_information(assigns) do
    ~H"""
    <div class="w-full bg-gray-900 rounded-xl shadow-lg p-6 border border-gray-700">
      <h2 class="text-2xl font-bold text-indigo-500 mb-4">
        Progress Information
      </h2>
      <div class="flex flex-col space-y-6">
        <.encoding_progress_inline progress={@encoding_progress} />
        <.crf_search_progress_inline progress={@crf_search_progress} />
        <.sync_progress_inline progress={@sync_progress} />
      </div>
    </div>
    """
  end

  # Inline encoding progress display
  defp encoding_progress_inline(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg p-4 shadow-md hover:bg-gray-700 transition-colors duration-200">
      <%= if @progress.filename != :none do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">Encoding:</span>
          <span class="font-mono">{ProgressHelpers.format_filename(@progress.filename)}</span>
          - {@progress.percent}%
        </div>
        
        <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
          <ul class="list-disc pl-5 fancy-list">
            <li>FPS: {ProgressHelpers.format_value(@progress.fps)}</li>
            <li>Speed: {ProgressHelpers.format_value(@progress.speed)}x</li>
            <li>Bitrate: {ProgressHelpers.format_value(@progress.bitrate)}</li>
            <li>Time: {ProgressHelpers.format_duration(@progress.time)}</li>
            <li>ETA: {ProgressHelpers.format_duration(@progress.eta)}</li>
          </ul>
        </div>
        
        <.progress_bar_inline percent={@progress.percent} color="indigo" />
      <% else %>
        <div class="text-center py-4">
          <p class="text-slate-400">No encoding in progress</p>
        </div>
      <% end %>
    </div>
    """
  end

  # Inline CRF search progress display
  defp crf_search_progress_inline(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg p-4 shadow-md hover:bg-gray-700 transition-colors duration-200">
      <%= if CrfSearchProgress.has_data?(@progress) do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">{CrfSearchProgress.display_filename(@progress)}</span>
          <%= if CrfSearchProgress.has_percent?(@progress) do %>
            - {@progress.percent}%
          <% end %>
        </div>
        
        <%= if build_crf_details(@progress) != [] do %>
          <div class="text-xs leading-5 text-gray-400 dark:text-gray-300 mb-2">
            <ul class="list-disc pl-5 fancy-list">
              <%= for detail <- build_crf_details(@progress) do %>
                <li>{detail}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
        
        <%= if CrfSearchProgress.has_percent?(@progress) do %>
          <.progress_bar_inline percent={@progress.percent} color="purple" />
        <% end %>
      <% else %>
        <div class="text-center py-4">
          <p class="text-slate-400">No CRF search in progress</p>
        </div>
      <% end %>
    </div>
    """
  end

  # Inline sync progress display
  defp sync_progress_inline(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg p-4 shadow-md hover:bg-gray-700 transition-colors duration-200">
      <%= if @progress > 0 do %>
        <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 mb-1">
          <span class="font-semibold">Sync Progress</span>
          - {@progress}%
        </div>
        
        <.progress_bar_inline percent={@progress} color="indigo" />
      <% else %>
        <div class="text-center py-4">
          <p class="text-slate-400">No sync operation in progress</p>
        </div>
      <% end %>
    </div>
    """
  end

  # Inline progress bar to avoid component nesting
  defp progress_bar_inline(assigns) do
    ~H"""
    <div class="flex items-center space-x-2">
      <div class="w-full bg-gray-600 rounded-full h-2.5 dark:bg-gray-500">
        <div
          class={"bg-#{@color}-600 h-2.5 rounded-full transition-all duration-300"}
          style={"width: #{max(@percent, 0)}%"}
        >
        </div>
      </div>
      <div class="text-sm leading-5 text-gray-100 dark:text-gray-200 font-mono">
        <strong>{@percent}%</strong>
      </div>
    </div>
    """
  end

  # Helper function for CRF search details
  defp build_crf_details(progress) do
    [
      {&CrfSearchProgress.has_crf?/1, fn p -> "CRF: #{ProgressHelpers.format_number(p.crf)}" end},
      {&CrfSearchProgress.has_score?/1, fn p -> "VMAF Score: #{ProgressHelpers.format_number(p.score)} (Target: 95)" end},
      {&CrfSearchProgress.has_fps?/1, fn p -> "FPS: #{ProgressHelpers.format_number(p.fps)}" end},
      {&CrfSearchProgress.has_eta?/1, fn p -> "ETA: #{ProgressHelpers.format_duration(p.eta)}" end}
    ]
    |> Enum.filter(fn {has_value?, _formatter} -> has_value?.(progress) end)
    |> Enum.map(fn {_has_value?, formatter} -> formatter.(progress) end)
  end
end
