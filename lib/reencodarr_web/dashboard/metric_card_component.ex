defmodule ReencodarrWeb.Dashboard.MetricCardComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="relative overflow-hidden rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6 hover:bg-white/10 transition-all duration-300">
      <div class="flex items-start justify-between">
        <div class="flex-1">
          <div class="flex items-center gap-3 mb-2">
            <span class="text-2xl">{@icon}</span>
            <h3 class="text-slate-200 text-sm font-semibold">{@title}</h3>
          </div>
          <p class="text-3xl font-bold text-white mb-1">{@value}</p>
          <p class="text-slate-300 text-xs font-medium">{@subtitle}</p>
        </div>

        <%= if assigns[:progress] do %>
          <div class="relative w-12 h-12">
            <svg class="w-12 h-12 transform -rotate-90" viewBox="0 0 36 36">
              <path
                class="text-slate-700"
                stroke="currentColor"
                stroke-width="3"
                fill="none"
                d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
              />
              <path
                class="text-cyan-400"
                stroke="currentColor"
                stroke-width="3"
                stroke-linecap="round"
                fill="none"
                stroke-dasharray={"#{@progress}, 100"}
                d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
              />
            </svg>
            <div class="absolute inset-0 flex items-center justify-center text-xs text-white font-semibold">
              {round(@progress)}%
            </div>
          </div>
        <% end %>
      </div>

      <div class={"absolute top-0 left-0 w-full h-1 bg-gradient-to-r #{@color}"}></div>
    </div>
    """
  end
end
