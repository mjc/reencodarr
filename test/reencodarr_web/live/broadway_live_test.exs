defmodule ReencodarrWeb.BroadwayLiveTest do
  @moduledoc """
  Tests for BroadwayLive pipeline monitor page.
  """
  use ReencodarrWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders pipeline monitor page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/broadway")

      assert html =~ "PIPELINE MONITOR"
      assert html =~ "STARDATE"
    end

    test "displays navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/broadway")

      assert html =~ "OVERVIEW"
      assert html =~ "FAILURES"
    end
  end

  describe "set_timezone event" do
    test "handles timezone change without crashing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/broadway")

      html = view |> render_click("set_timezone", %{"timezone" => "America/New_York"})

      assert html =~ "PIPELINE MONITOR"
    end

    test "handles UTC timezone", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/broadway")

      html = view |> render_click("set_timezone", %{"timezone" => "UTC"})

      assert html =~ "PIPELINE MONITOR"
    end
  end
end
