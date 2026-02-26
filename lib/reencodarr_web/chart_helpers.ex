defmodule ReencodarrWeb.ChartHelpers do
  @moduledoc """
  SVG coordinate calculation helpers for the CRF search scatter chart.

  Maps CRF and VMAF values to SVG coordinates within the chart viewBox.
  All coordinate helpers use a fixed chart area:
  - X: 30 (left) to 310 (right) — 280px wide
  - Y: 10 (top) to 110 (bottom) — 100px tall
  """

  @chart_left 30
  @chart_right 310
  @chart_width @chart_right - @chart_left
  @chart_top 10
  @chart_bottom 110
  @chart_height @chart_bottom - @chart_top

  @doc """
  Maps a CRF value to an x-coordinate within the chart bounds.

  Uses a dynamic range so the chart axis adapts to the actual CRF values
  being searched, whether that's the default 5-70 range or a narrow
  hint-derived range like 18-30.
  """
  @spec crf_to_x(number(), number(), number()) :: float()
  def crf_to_x(crf, crf_min, crf_max) when crf_max > crf_min do
    @chart_left + (crf - crf_min) / (crf_max - crf_min) * @chart_width
  end

  @doc """
  Maps a VMAF score to a y-coordinate within the chart bounds.

  Higher VMAF scores map to lower y values (top of chart).
  """
  @spec vmaf_to_y(number(), number(), number()) :: float()
  def vmaf_to_y(score, vmaf_min, vmaf_max) when vmaf_max > vmaf_min do
    @chart_top + (1 - (score - vmaf_min) / (vmaf_max - vmaf_min)) * @chart_height
  end

  @doc """
  Generates evenly-spaced integer tick values for the CRF x-axis.

  Produces 3-7 ticks including the boundary values, with even spacing
  that adapts to the range width.
  """
  @spec generate_x_ticks(integer(), integer()) :: [integer()]
  def generate_x_ticks(crf_min, crf_max) when crf_max > crf_min do
    range_size = crf_max - crf_min

    # Choose a step that gives us 3-7 ticks
    step =
      cond do
        range_size <= 10 -> 2
        range_size <= 20 -> 4
        range_size <= 40 -> 8
        range_size <= 80 -> 16
        true -> div(range_size, 4)
      end

    # Generate interior ticks at even multiples of step
    first_tick = crf_min + step - rem(crf_min, step)

    interior =
      first_tick
      |> Stream.iterate(&(&1 + step))
      |> Enum.take_while(&(&1 < crf_max))

    ([crf_min] ++ interior ++ [crf_max])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Computes a CRF min/max range from a list of result maps.

  Each result is expected to have a `:crf` key. Pads the range by 2
  on each side so dots don't sit exactly on the axis edges.
  Falls back to {8, 40} for empty results.
  """
  @spec crf_range_from_results([map()]) :: {number(), number()}
  def crf_range_from_results([]), do: {8, 40}

  def crf_range_from_results(results) do
    crfs = Enum.map(results, & &1.crf)
    crf_min = Enum.min(crfs)
    crf_max = Enum.max(crfs)

    # Pad by 2 on each side; ensure at least 4 units of range
    padded_min = crf_min - 2
    padded_max = max(crf_max + 2, padded_min + 4)

    {padded_min, padded_max}
  end
end
