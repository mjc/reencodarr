defmodule ReencodarrWeb.SummaryRowComponent do
  use Phoenix.LiveComponent

  attr :stats, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row items-center justify-between bg-gray-800 rounded-lg shadow-lg p-6 border border-gray-700">
      <div class="text-gray-300">
        <h2 class="text-xl font-bold">Summary</h2>
        <p class="text-sm">Overview of current statistics</p>
      </div>

      <div class="flex flex-wrap gap-4">
        <div class="flex flex-col items-center">
          <span class="text-indigo-400 font-bold text-lg">{@stats.total_videos}</span>
          <span class="text-gray-500 text-sm">Total Videos</span>
        </div>
        <div class="flex flex-col items-center">
          <span class="text-indigo-400 font-bold text-lg">{@stats.reencoded}</span>
          <span class="text-gray-500 text-sm">Reencoded</span>
        </div>
        <div class="flex flex-col items-center">
          <span class="text-indigo-400 font-bold text-lg">{@stats.not_reencoded}</span>
          <span class="text-gray-500 text-sm">Not Reencoded</span>
        </div>
        <div class="flex flex-col items-center">
          <span class="text-indigo-400 font-bold text-lg">{@stats.avg_vmaf_percentage}</span>
          <span class="text-gray-500 text-sm">Avg VMAF %</span>
        </div>
      </div>
    </div>
    """
  end
end
