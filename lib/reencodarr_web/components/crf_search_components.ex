defmodule ReencodarrWeb.CrfSearchComponents do
  @moduledoc "Shared chart for measured CRF search results."
  use Phoenix.Component
  alias Reencodarr.Formatters
  alias ReencodarrWeb.ChartHelpers

  attr :results, :list, required: true
  attr :target_vmaf, :integer, required: true
  attr :testing_crf, :float, default: nil

  def crf_search_chart(assigns) do
    scores = Enum.map(assigns.results, & &1.score)

    vmaf_min =
      min(assigns.target_vmaf - 3, Enum.min(scores, fn -> assigns.target_vmaf - 3 end) - 1)

    vmaf_max =
      max(assigns.target_vmaf + 3, Enum.max(scores, fn -> assigns.target_vmaf + 3 end) + 1)

    {crf_min, crf_max} = ChartHelpers.crf_range_from_results(assigns.results)

    dots =
      Enum.with_index(assigns.results, fn r, idx ->
        %{
          x: ChartHelpers.crf_to_x(r.crf, crf_min, crf_max),
          y: ChartHelpers.vmaf_to_y(r.score, vmaf_min, vmaf_max),
          crf: r.crf,
          score: r.score,
          above: r.score >= assigns.target_vmaf,
          is_latest: idx == length(assigns.results) - 1
        }
      end)

    target_y = ChartHelpers.vmaf_to_y(assigns.target_vmaf, vmaf_min, vmaf_max)

    y_ticks =
      for vmaf <- trunc(vmaf_min)..trunc(vmaf_max) do
        %{value: vmaf, y: ChartHelpers.vmaf_to_y(vmaf, vmaf_min, vmaf_max)}
      end

    x_ticks =
      for crf <- ChartHelpers.generate_x_ticks(trunc(crf_min), trunc(crf_max)) do
        %{value: crf, x: ChartHelpers.crf_to_x(crf, crf_min, crf_max)}
      end

    assigns =
      assign(assigns,
        vmaf_min: vmaf_min,
        vmaf_max: vmaf_max,
        crf_min: crf_min,
        crf_max: crf_max,
        dots: dots,
        target_y: target_y,
        y_ticks: y_ticks,
        x_ticks: x_ticks
      )

    ~H"""
    <svg viewBox="0 0 320 140" class="w-full" style="max-height: 200px;">
      <%= for tick <- @y_ticks do %>
        <line
          x1="30"
          y1={tick.y}
          x2="310"
          y2={tick.y}
          stroke="#374151"
          stroke-width="0.5"
          opacity="0.3"
        />
      <% end %>

      <line
        x1="30"
        y1={@target_y}
        x2="310"
        y2={@target_y}
        stroke="#f59e0b"
        stroke-width="1.5"
        stroke-dasharray="6,4"
      />
      <text x="312" y={@target_y + 3} fill="#f59e0b" font-size="9" font-family="inherit">
        {@target_vmaf}
      </text>

      <%= for dot <- @dots do %>
        <circle
          cx={dot.x}
          cy={dot.y}
          r="5"
          fill={if dot.above, do: "#4ade80", else: "#f87171"}
          opacity="0.9"
        />
        <%= if dot.is_latest do %>
          <text
            x={dot.x}
            y={dot.y - 8}
            fill="#9ca3af"
            font-size="9"
            font-family="inherit"
            text-anchor="middle"
          >
            {Formatters.vmaf_score(dot.score, 1)}
          </text>
        <% end %>
      <% end %>

      <%= if @testing_crf do %>
        <circle
          cx={ChartHelpers.crf_to_x(@testing_crf, @crf_min, @crf_max)}
          cy="115"
          r="4"
          fill="none"
          stroke="#60a5fa"
          stroke-width="1.5"
        />
        <text
          x={ChartHelpers.crf_to_x(@testing_crf, @crf_min, @crf_max)}
          y="127"
          fill="#60a5fa"
          font-size="8"
          font-family="inherit"
          text-anchor="middle"
        >
          CRF {Formatters.crf(@testing_crf)}
        </text>
      <% end %>

      <%= for tick <- @y_ticks do %>
        <text x="2" y={tick.y + 3} fill="#9ca3af" font-size="9" font-family="inherit">
          {tick.value}
        </text>
      <% end %>

      <%= for tick <- @x_ticks do %>
        <text
          x={tick.x}
          y="135"
          fill="#9ca3af"
          font-size="9"
          font-family="inherit"
          text-anchor="middle"
        >
          {tick.value}
        </text>
      <% end %>

      <line x1="30" y1="10" x2="30" y2="110" stroke="#4b5563" stroke-width="1" />
      <line x1="30" y1="110" x2="310" y2="110" stroke="#4b5563" stroke-width="1" />
    </svg>
    """
  end
end
