defmodule ReencodarrWeb.PageControllerTest do
  use ReencodarrWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "TOTAL VMAFS"
  end
end
