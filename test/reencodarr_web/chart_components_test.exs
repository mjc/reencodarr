defmodule ReencodarrWeb.ChartComponentsTest do
  use Reencodarr.UnitCase, async: true

  import Phoenix.LiveViewTest

  test "bar_chart strips embedded svg stylesheet output from Contex" do
    html =
      render_component(&ReencodarrWeb.ChartComponents.bar_chart/1,
        data: [{"HEVC", 12}, {"AV1", 8}],
        title: "Codec Distribution",
        width: 400,
        height: 220
      )

    refute html =~ ~s(<style type="text/css">)
    assert html =~ ~s(class="chart")
    assert html =~ ~s(stroke="#4B5563")
  end
end
