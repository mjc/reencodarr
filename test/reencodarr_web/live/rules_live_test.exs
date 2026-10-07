defmodule ReencodarrWeb.RulesLiveTest do
  use ReencodarrWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias ReencodarrWeb.RulesLive.Sections

  test "opens the workflow and shows server analysis separately from workers", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/rules")
    assert has_element?(view, "h1", "Encoding rules")
    assert has_element?(view, "#rule-section", "The server reads file metadata")

    assert has_element?(
             view,
             "nav[aria-label='Rule sections'] a[aria-current='page']",
             "Workflow"
           )
  end

  test "sections are bookmarkable and navigation patches the URL", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/rules?section=audio_rules")
    assert has_element?(view, "#rule-section", "Existing Opus, TrueHD Atmos")
    view |> element("a[href='/rules?section=crf_search']") |> render_click()
    assert_patch(view, "/rules?section=crf_search")
    assert has_element?(view, "#rule-section", "6/8 means six samples of the current CRF trial")
    refute has_element?(view, "#rule-section", "Existing Opus")
  end

  test "unknown section falls back to workflow", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/rules?section=unknown")
    assert has_element?(view, "#rule-section h2", "Workflow")
  end

  test "every reference section can be reached", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/rules")

    for section <- Sections.all() do
      view |> element("a[href='/rules?section=#{section.id}']") |> render_click()
      assert has_element?(view, "#rule-section h2", section.title)
    end
  end
end
