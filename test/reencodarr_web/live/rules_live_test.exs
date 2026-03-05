defmodule ReencodarrWeb.RulesLiveTest do
  @moduledoc """
  Tests for RulesLive encoding rules documentation page.
  """
  use ReencodarrWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders encoding rules page with overview section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      assert html =~ "Encoding Rules Documentation"
    end

    test "shows overview section by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      assert html =~ "Learn how Reencodarr automatically optimizes"
    end
  end

  describe "select_section event" do
    test "switching to video_rules section renders that section", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "video_rules"})

      assert html =~ "Encoding Rules Documentation"
    end

    test "switching to audio_rules section does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "audio_rules"})

      assert html =~ "Encoding Rules Documentation"
    end

    test "switching to hdr_support section does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "hdr_support"})

      assert html =~ "Encoding Rules Documentation"
    end

    test "switching to crf_search section does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "crf_search"})

      assert html =~ "Encoding Rules Documentation"
    end

    test "unknown section is ignored gracefully", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "nonexistent_section"})

      assert html =~ "Encoding Rules Documentation"
    end
  end
end
