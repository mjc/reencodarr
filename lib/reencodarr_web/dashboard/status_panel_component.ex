defmodule ReencodarrWeb.Dashboard.StatusPanelComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white/5 backdrop-blur-sm border border-white/10 p-6">
      <h2 class="text-xl font-semibold text-white mb-6 flex items-center gap-2">
        <span class="text-xl">⚡</span>
        Real-time Status
      </h2>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <.status_item
          title="Encoding"
          active={@encoding}
          progress={@encoding_progress}
          color="from-emerald-500 to-teal-500"
        />

        <.status_item
          title="CRF Search"
          active={@crf_searching}
          progress={@crf_search_progress}
          color="from-blue-500 to-cyan-500"
        />

        <.status_item
          title="Sync"
          active={@syncing}
          progress={@sync_progress}
          color="from-violet-500 to-purple-500"
          simple_progress={true}
        />
      </div>
    </div>
    """
  end

  defp status_item(assigns) do
    assigns = assign_new(assigns, :simple_progress, fn -> false end)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <span class="text-slate-200 text-sm font-semibold">{@title}</span>
        <.status_indicator active={@active} />
      </div>

      <%= if @active and should_show_progress?(@progress, @simple_progress) do %>
        <.progress_bar
          label="Progress"
          value={get_progress_value(@progress, @simple_progress)}
          color={@color}
        />

        <%= if not @simple_progress and get_filename(@progress) do %>
          <p class="text-xs text-slate-300 truncate font-medium" title={get_filename(@progress)}>
            {get_display_filename(@progress)}
          </p>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp status_indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <div class={[
        "w-2 h-2 rounded-full",
        if(@active, do: "bg-emerald-400 animate-pulse", else: "bg-slate-600")
      ]}></div>
      <span class={[
        "text-xs font-semibold",
        if(@active, do: "text-emerald-300", else: "text-slate-400")
      ]}>
        {if @active, do: "Active", else: "Idle"}
      </span>
    </div>
    """
  end

  defp progress_bar(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="flex justify-between text-xs">
        <span class="text-slate-300 font-medium">{@label}</span>
        <span class="text-slate-100 font-semibold">{@value}%</span>
      </div>
      <div class="w-full bg-slate-700 rounded-full h-2 overflow-hidden">
        <div
          class={"h-full bg-gradient-to-r #{@color} transition-all duration-300 ease-out"}
          style={"width: #{@value}%"}
        ></div>
      </div>
    </div>
    """
  end

  # Helper functions to normalize progress data
  defp should_show_progress?(progress, true), do: is_number(progress) and progress > 0
  defp should_show_progress?(progress, false), do: is_map(progress) and map_size(progress) > 0

  defp get_progress_value(progress, true), do: progress
  defp get_progress_value(progress, false), do: Map.get(progress, :percent, 0)

  defp get_filename(progress) when is_map(progress), do: Map.get(progress, :filename)
  defp get_filename(_), do: nil

  defp get_display_filename(progress) do
    case get_filename(progress) do
      filename when is_binary(filename) -> Path.basename(filename)
      :none -> "Unknown"
      _ -> "Unknown"
    end
  end
end
