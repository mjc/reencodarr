defmodule ReencodarrWeb.Dashboard.QueueDisplayComponent do
  use ReencodarrWeb, :live_component

  @moduledoc "Displays a queue of items in the dashboard."

  def render(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
      <div class="flex items-center justify-between mb-6">
        <h3 class="text-lg font-semibold text-white flex items-center gap-2">
          <span class="text-lg">{@queue.icon}</span>
          {@queue.title}
        </h3>
        <span class="text-sm text-slate-300 bg-white/10 px-3 py-1 rounded-full font-medium">
          {length(@queue.files)} items
        </span>
      </div>

      <%= if @queue.files == [] do %>
        <div class="text-center py-8">
          <div class="text-4xl mb-2">🎉</div>
          <p class="text-slate-400">Queue is empty!</p>
        </div>
      <% else %>
        <div class="space-y-3 max-h-60 overflow-y-auto">
          <%= for file <- @queue.files do %>
            <div class="flex items-center gap-3 p-3 rounded-lg bg-white/5 hover:bg-white/10 transition-colors">
              <div class={[
                "w-8 h-8 rounded-full flex items-center justify-center text-xs font-semibold text-white",
                "bg-gradient-to-r #{@queue.color}"
              ]}>
                {file.index}
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm text-white truncate" title={file.path}>
                  {file.display_name}
                </p>
                <%= if file.estimated_percent do %>
                  <p class="text-xs text-slate-400">
                    ~{file.estimated_percent}% complete
                  </p>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if length(@queue.files) == 10 do %>
            <div class="text-center py-2">
              <span class="text-xs text-slate-400">
                Showing first 10 items
              </span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
