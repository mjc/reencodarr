defmodule ReencodarrWeb.ChartComponentsTest do
  use Reencodarr.UnitCase, async: true

  import Phoenix.LiveViewTest

  test "bar_chart renders lightweight html rows" do
    html =
      render_component(&ReencodarrWeb.ChartComponents.bar_chart/1,
        data: [{"HEVC", 12}, {"AV1", 8}],
        title: "Codec Distribution",
        width: 400,
        height: 220
      )

    assert html =~ "Codec Distribution"
    assert html =~ "HEVC"
    assert html =~ "AV1"
    refute html =~ "<svg"
  end
end
