defmodule ReencodarrWeb.ChartHelpersTest do
  use ExUnit.Case, async: true

  alias ReencodarrWeb.ChartHelpers

  @chart_left 30
  @chart_right 310

  describe "crf_to_x/3 dynamic range" do
    test "maps crf_min to left edge of chart" do
      assert ChartHelpers.crf_to_x(8, 8, 40) == @chart_left
    end

    test "maps crf_max to right edge of chart" do
      assert ChartHelpers.crf_to_x(40, 8, 40) == @chart_right
    end

    test "maps midpoint CRF to center of chart" do
      mid_x = ChartHelpers.crf_to_x(24, 8, 40)
      expected_center = @chart_left + (@chart_right - @chart_left) / 2
      assert_in_delta mid_x, expected_center, 0.1
    end

    test "handles narrow CRF range from hints (18-30)" do
      # CRF 18 should map to left edge
      assert ChartHelpers.crf_to_x(18, 18, 30) == @chart_left
      # CRF 30 should map to right edge
      assert ChartHelpers.crf_to_x(30, 18, 30) == @chart_right
    end

    test "handles wide CRF range (5-70)" do
      assert ChartHelpers.crf_to_x(5, 5, 70) == @chart_left
      assert ChartHelpers.crf_to_x(70, 5, 70) == @chart_right
    end

    test "all results within chart bounds for any range" do
      for {crf_min, crf_max} <- [{5, 70}, {18, 30}, {8, 40}, {10, 55}] do
        for crf <- crf_min..crf_max do
          x = ChartHelpers.crf_to_x(crf, crf_min, crf_max)

          assert x >= @chart_left,
                 "CRF #{crf} in range #{crf_min}-#{crf_max} produced x=#{x} < #{@chart_left}"

          assert x <= @chart_right,
                 "CRF #{crf} in range #{crf_min}-#{crf_max} produced x=#{x} > #{@chart_right}"
        end
      end
    end
  end

  describe "vmaf_to_y/3" do
    test "maps vmaf_max to top of chart (y=10)" do
      assert ChartHelpers.vmaf_to_y(100, 90, 100) == 10
    end

    test "maps vmaf_min to bottom of chart (y=110)" do
      assert ChartHelpers.vmaf_to_y(90, 90, 100) == 110
    end

    test "maps midpoint to center" do
      y = ChartHelpers.vmaf_to_y(95, 90, 100)
      assert_in_delta y, 60.0, 0.1
    end
  end

  describe "generate_x_ticks/2" do
    test "generates ticks within range for standard range" do
      ticks = ChartHelpers.generate_x_ticks(8, 40)

      for tick <- ticks do
        assert tick >= 8
        assert tick <= 40
      end
    end

    test "generates ticks within range for narrow range" do
      ticks = ChartHelpers.generate_x_ticks(18, 30)

      for tick <- ticks do
        assert tick >= 18
        assert tick <= 30
      end
    end

    test "generates ticks within range for wide range" do
      ticks = ChartHelpers.generate_x_ticks(5, 70)

      for tick <- ticks do
        assert tick >= 5
        assert tick <= 70
      end
    end

    test "generates reasonable number of ticks (3-7)" do
      for {crf_min, crf_max} <- [{5, 70}, {18, 30}, {8, 40}, {10, 55}] do
        ticks = ChartHelpers.generate_x_ticks(crf_min, crf_max)
        count = length(ticks)
        assert count >= 3, "Too few ticks (#{count}) for range #{crf_min}-#{crf_max}"
        assert count <= 7, "Too many ticks (#{count}) for range #{crf_min}-#{crf_max}"
      end
    end

    test "includes boundary values" do
      ticks = ChartHelpers.generate_x_ticks(10, 50)
      assert 10 in ticks
      assert 50 in ticks
    end
  end

  describe "crf_range_from_results/1" do
    test "computes range from result CRF values with padding" do
      results = [%{crf: 20, score: 95.0}, %{crf: 25, score: 93.0}, %{crf: 30, score: 91.0}]
      {crf_min, crf_max} = ChartHelpers.crf_range_from_results(results)

      # Should include all results
      assert crf_min <= 20
      assert crf_max >= 30
    end

    test "provides reasonable defaults for empty results" do
      {crf_min, crf_max} = ChartHelpers.crf_range_from_results([])
      assert crf_min < crf_max
    end

    test "pads range so dots aren't on the axis edges" do
      results = [%{crf: 25, score: 95.0}]
      {crf_min, crf_max} = ChartHelpers.crf_range_from_results(results)

      # Single result shouldn't map to exact edges
      assert crf_min < 25
      assert crf_max > 25
    end
  end
end
