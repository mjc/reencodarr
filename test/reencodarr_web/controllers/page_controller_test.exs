defmodule ReencodarrWeb.PageControllerTest do
  use ReencodarrWeb.ConnCase
  import ExUnit.CaptureLog

  test "GET /", %{conn: conn} do
    capture_log(fn ->
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)

      # Should contain the DashboardLive content
      assert response =~ "Processing Pipeline"
    end)
  end
end
