defmodule ReencodarrWeb.PageControllerTest do
  use ReencodarrWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    # Should contain either the loading state or the actual dashboard content
    assert response =~ "Loading dashboard data..." or response =~ "TOTAL VMAFS"
  end
end
