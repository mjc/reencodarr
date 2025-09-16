defmodule ReencodarrWeb.SummaryRowComponent do
  @moduledoc """
  Summary row component optimized as a function component.

  Since this component only displays data without managing state,
  it's been converted to a function component for better performance.
  """

  use Phoenix.Component

  @doc """
  Renders a summary row with statistics.

  ## Attributes

    * `stats` - Map containing statistical data to display
  """
  attr :stats, :map, required: true

  def summary_row(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row items-center justify-between bg-gray-800 rounded-lg shadow-lg p-6 border border-gray-700">
      <div class="text-gray-300">
        <h2 class="text-xl font-bold">Summary</h2>
        <p class="text-sm">Overview of current statistics</p>
      </div>

      <div class="flex flex-wrap gap-4">
        <.stat_item
          value={@stats.total_videos}
          label="Total Videos"
        />
        <.stat_item
          value={@stats.reencoded_count}
          label="Reencoded"
        />
        <.stat_item
          value={@stats.total_videos - @stats.reencoded_count}
          label="Not Reencoded"
        />
        <.stat_item
          value={@stats.avg_vmaf_percentage}
          label="Avg VMAF %"
        />
      </div>
    </div>
    """
  end

  defp stat_item(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <span class="text-indigo-400 font-bold text-lg">{@value}</span>
      <span class="text-gray-500 text-sm">{@label}</span>
    </div>
    """
  end
end
