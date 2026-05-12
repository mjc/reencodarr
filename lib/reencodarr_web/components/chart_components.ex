defmodule ReencodarrWeb.ChartComponents do
  @moduledoc "Lightweight dashboard chart components."

  use Phoenix.Component

  @colour_palette [
    "bg-violet-500",
    "bg-indigo-500",
    "bg-blue-500",
    "bg-cyan-500",
    "bg-emerald-500",
    "bg-amber-500",
    "bg-red-500",
    "bg-pink-500"
  ]

  @doc "Renders a compact dashboard bar chart without SVG layout overhead."
  attr :data, :list, required: true
  attr :title, :string, default: ""
  attr :width, :integer, default: 500
  attr :height, :integer, default: 200
  attr :orientation, :atom, default: :horizontal

  def bar_chart(assigns) do
    rows = chart_rows(assigns.data)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:empty?, rows == [])

    ~H"""
    <div class="chart-container dashboard-card dashboard-chart-card bg-gray-800 rounded-lg border border-gray-700 p-4">
      <h3 :if={@title != ""} class="text-sm font-semibold text-gray-300 mb-3">{@title}</h3>

      <%= if @empty? do %>
        <div class="flex h-[220px] items-center justify-center text-sm text-gray-500">
          No data available
        </div>
      <% else %>
        <div class="space-y-3">
          <%= for row <- @rows do %>
            <div class="grid grid-cols-[minmax(0,7rem)_minmax(0,1fr)_auto] items-center gap-3">
              <div class="truncate text-xs text-gray-400" title={row.label}>{row.label}</div>
              <div class="h-3 overflow-hidden rounded-full bg-gray-900">
                <div
                  class={["h-full rounded-full", row.colour_class]}
                  style={"width: #{row.width_percent}%"}
                  title={row.title}
                >
                </div>
              </div>
              <div class="text-xs font-mono text-gray-300">{row.value}</div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp chart_rows(data) do
    cleaned =
      data
      |> Enum.filter(fn
        {_, value} when is_number(value) -> value > 0
        _ -> false
      end)

    case cleaned do
      [] ->
        []

      _ ->
        max_value =
          cleaned
          |> Enum.map(fn {_, value} -> value end)
          |> Enum.max()

        cleaned
        |> Enum.with_index()
        |> Enum.map(fn {{label, value}, index} ->
          %{
            label: to_string(label),
            value: format_value(value),
            width_percent: width_percent(value, max_value),
            colour_class: Enum.at(@colour_palette, rem(index, length(@colour_palette))),
            title: "#{label}: #{value}"
          }
        end)
    end
  end

  defp width_percent(_value, 0), do: 0
  defp width_percent(value, max_value), do: Float.round(value / max_value * 100.0, 1)

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
end
