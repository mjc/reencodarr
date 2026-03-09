defmodule ReencodarrWeb.ChartComponents do
  @moduledoc "Contex-based SVG chart components for the dashboard."

  use Phoenix.Component

  # Palette: purple/blue tones matching dark theme (hex without #)
  @colour_palette ["8B5CF6", "6366F1", "3B82F6", "06B6D4", "10B981", "F59E0B", "EF4444", "EC4899"]

  @doc "Renders a bar chart inside a dark-themed card."
  attr :data, :list, required: true
  attr :title, :string, default: ""
  attr :width, :integer, default: 500
  attr :height, :integer, default: 200
  attr :orientation, :atom, default: :horizontal

  def bar_chart(assigns) do
    chart_svg = build_bar_chart(assigns.data, assigns.width, assigns.height, assigns.orientation)
    assigns = assign(assigns, :chart_svg, chart_svg)

    ~H"""
    <div class="chart-container bg-gray-800 rounded-lg border border-gray-700 p-4">
      <h3 :if={@title != ""} class="text-sm font-semibold text-gray-300 mb-3">{@title}</h3>
      <div class="overflow-x-auto">
        {@chart_svg}
      </div>
    </div>
    """
  end

  defp build_bar_chart(data, width, height, orientation) do
    if Enum.empty?(data) or Enum.all?(data, fn {_, v} -> v == 0 end) do
      empty_svg(width, height)
    else
      dataset = Contex.Dataset.new(data, ["Category", "Count"])

      Contex.Plot.new(dataset, Contex.BarChart, width, height,
        orientation: orientation,
        colour_palette: @colour_palette,
        data_labels: true,
        padding: 3,
        legend_setting: :legend_none
      )
      |> Contex.Plot.axis_labels("", "")
      |> Contex.Plot.to_svg()
    end
  end

  defp empty_svg(width, height) do
    cx = div(width, 2)
    cy = div(height, 2)

    {:safe,
     "<svg width='#{width}' height='#{height}'>" <>
       "<text x='#{cx}' y='#{cy}' text-anchor='middle' fill='#6B7280' font-size='14'>No data available</text>" <>
       "</svg>"}
  end
end
