defmodule ReencodarrWeb.SetupPreviewLiveTest do
  use ReencodarrWeb.ConnCase, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  describe "setup preview route" do
    test "renders the preview chooser and default guided mode", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup-preview")

      assert html =~ "Compare setup looks before we commit"
      assert html =~ "Guided onboarding"
      assert html =~ "Dashboard-native"
      assert html =~ "Diagnostic-first"
      assert html =~ "Split-pane"
      assert html =~ "Minimal calm"
      assert html =~ "First run"
      assert html =~ "Repair"
      assert html =~ "Setup required"
    end

    test "supports directly previewing the minimal repair variant", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup-preview?variant=minimal&mode=repair")

      assert html =~ "Minimal calm"
      assert html =~ "Repair your Radarr connection without stopping the rest of the app"
      assert html =~ "Radarr needs attention"
      assert html =~ "Open repair flow"
    end

    test "renders the requested preview in the first HTTP response", %{conn: conn} do
      html =
        conn
        |> get(~p"/setup-preview?variant=minimal&mode=repair")
        |> html_response(200)

      assert html =~ "Minimal calm"
      assert html =~ "Repair your Radarr connection without stopping the rest of the app"
      assert html =~ "Radarr needs attention"
    end
  end
end
