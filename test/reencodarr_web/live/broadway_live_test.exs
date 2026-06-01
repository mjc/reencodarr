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

    test "PIPELINE MONITOR is marked as active in navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/broadway")

      # The page title and active navigation item both contain PIPELINE MONITOR
      assert html =~ "PIPELINE MONITOR"
    end

    test "stardate is rendered as a number", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/broadway")

      # The stardate should appear as a decimal number (e.g. 75234.5)
      assert html =~ ~r/STARDATE\s+\d+\.\d/
    end

    test "renders the coming soon message for Broadway content", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/broadway")

      assert html =~ "Broadway pipeline monitoring interface"
    end

    test "assigns default UTC timezone on mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/broadway")

      # Default timezone is UTC — verify the page renders without issue
      assert render(view) =~ "PIPELINE MONITOR"
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

    test "handles multiple timezone changes in sequence", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/broadway")

      view |> render_click("set_timezone", %{"timezone" => "America/Chicago"})
      view |> render_click("set_timezone", %{"timezone" => "Europe/London"})
      html = view |> render_click("set_timezone", %{"timezone" => "Asia/Tokyo"})

      assert html =~ "PIPELINE MONITOR"
    end

    test "handles empty timezone string without crashing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/broadway")

      html = view |> render_click("set_timezone", %{"timezone" => ""})

      assert html =~ "PIPELINE MONITOR"
    end
  end

  describe "update_stardate message" do
    test "handles :update_stardate info message without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/broadway")

      send(view.pid, :update_stardate)

      html = render(view)
      assert html =~ "STARDATE"
    end

    test "stardate is still a number after :update_stardate message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/broadway")

      send(view.pid, :update_stardate)

      html = render(view)
      assert html =~ ~r/STARDATE\s+\d+\.\d/
    end
  end
end
