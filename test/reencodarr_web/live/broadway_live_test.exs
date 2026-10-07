defmodule ReencodarrWeb.BroadwayLiveTest do
  use ReencodarrWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "legacy pipeline URL opens the dashboard", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/broadway")
  end
end
