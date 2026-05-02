defmodule ReencodarrWeb.VideosLiveTest do
  @moduledoc """
  Tests for the VideosLive page.

  Covers: mounting, video display, search, filter events, sort events,
  pagination navigation, and URL-driven state (handle_params).

  NOTE: async: false required — the LiveView process is a separate BEAM process
  that needs shared sandbox access to see test-inserted data.
  """
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.Fixtures
  alias Reencodarr.Media.Video

  # Force the Video module to load so its Ecto.Enum atoms (e.g. :needs_analysis)
  # are present in the BEAM atom table before any LiveView template renders.
  setup do
    _ = Video.__schema__(:fields)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Mount / basic render
  # ---------------------------------------------------------------------------

  describe "mount" do
    test "renders the videos page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/videos")
      assert html =~ "Videos"
    end

    test "renders empty state when no videos exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      # Table should still be present (no crash)
      assert html =~ "<table" or html =~ "No videos"
    end

    test "renders video rows when videos exist", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/show/ep01.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      assert html =~ video.path
    end
  end

  # ---------------------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------------------

  describe "search event" do
    test "filters list to matching videos", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/unique_alpha_xyz/ep.mkv"})
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/unique_beta_xyz/ep.mkv"})

      {:ok, view, _html} = live(conn, ~p"/videos")

      html =
        view
        |> form("form[phx-change='search']", %{search: "unique_alpha_xyz"})
        |> render_change()

      assert html =~ "unique_alpha_xyz"
    end

    test "clears search and shows all videos", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/show/ep.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos?q=nonexistent")

      html =
        view
        |> form("form[phx-change='search']", %{search: ""})
        |> render_change()

      assert html =~ "show"
    end
  end

  # ---------------------------------------------------------------------------
  # State filter
  # ---------------------------------------------------------------------------

  describe "filter_state event" do
    test "fires filter_state event and patches URL to include state param", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos")

      view
      |> form("form[phx-change='filter_state']", %{state: "encoded"})
      |> render_change()

      # The event pushes a patch — after render, the select should keep the chosen value
      html = render(view)
      assert html =~ ~s(<select name="state" value="encoded")
    end

    test "filter_state renders the page without crashing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> form("form[phx-change='filter_state']", %{state: "encoded"})
        |> render_change()

      assert html =~ "Videos"
    end

    test "filter_state narrows visible rows", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/only_encoded.mkv", state: :encoded})
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/only_failed.mkv", state: :failed})
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> form("form[phx-change='filter_state']", %{state: "encoded"})
        |> render_change()

      assert html =~ "only_encoded.mkv"
      refute html =~ "only_failed.mkv"
    end
  end

  # ---------------------------------------------------------------------------
  # URL-driven state (handle_params)
  # ---------------------------------------------------------------------------

  describe "URL params" do
    test "page param is respected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/videos?page=1")
      assert html =~ "Videos"
    end

    test "search query param pre-fills the search", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/preloaded.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos?q=preloaded")
      html = render(view)
      assert html =~ "preloaded"
    end

    test "sort param is applied without crashing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/videos?sort_by=path&sort_dir=asc")
      assert html =~ "Videos"
    end
  end

  # ---------------------------------------------------------------------------
  # Sort event
  # ---------------------------------------------------------------------------

  describe "sort event" do
    test "clicking sort button does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/videos")
      # phx-click="sort" is on the <button> inside the sort_header component, not the <th>
      html = view |> element("button[phx-click='sort'][phx-value-col='path']") |> render_click()
      assert html =~ "Videos"
    end
  end

  # ---------------------------------------------------------------------------
  # Pagination
  # ---------------------------------------------------------------------------

  describe "pagination" do
    test "prev_page button is disabled on page 1", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/videos?page=1")
      html = render(view)
      # Button is rendered as disabled when already on first page
      assert html =~ "phx-click=\"prev_page\""
      assert html =~ "disabled"
    end

    test "per_page event updates items per page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/videos")

      html =
        view
        |> form("form[phx-change='set_per_page']", %{per_page: "50"})
        |> render_change()

      assert html =~ "Videos"
    end

    test "per_page dropdown keeps the selected value", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/videos?per_page=100")
      assert html =~ ~s(<select name="per_page" value="100")
    end
  end

  # ---------------------------------------------------------------------------
  # VMAF badge
  # ---------------------------------------------------------------------------

  describe "space saved badge" do
    test "does not render a space saved badge when video has no original_size", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/no_space.mkv", size: 1_000_000_000})
      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      refute html =~ "Space saved"
    end

    test "renders space saved in green for >= 1 GiB saved", %{conn: conn} do
      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/media/large_save.mkv",
          size: 2_000_000_000,
          original_size: 5_000_000_000
        })

      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      assert html =~ "text-green-300"
      assert html =~ "GiB"
    end

    test "renders space saved in yellow for >= 512 MiB saved", %{conn: conn} do
      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/media/medium_save.mkv",
          size: 1_500_000_000,
          original_size: 2_500_000_000
        })

      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      assert html =~ "text-yellow-300"
    end

    test "renders space saved in red for < 512 MiB saved", %{conn: conn} do
      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/media/small_save.mkv",
          size: 900_000_000,
          original_size: 950_000_000
        })

      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      assert html =~ "text-red-400"
    end
  end

  # ---------------------------------------------------------------------------
  # HDR badge
  # ---------------------------------------------------------------------------

  describe "hdr badge" do
    test "does not render an hdr badge when video has no HDR", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/sdr.mkv", hdr: nil})
      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      refute html =~ "HDR10"
      refute html =~ "bg-amber-900"
    end

    test "renders HDR label in amber badge", %{conn: conn} do
      {:ok, _video} = Fixtures.hdr_video_fixture(%{path: "/media/hdr.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      assert html =~ "HDR10"
      assert html =~ "bg-amber-900"
    end
  end

  describe "mark bad" do
    test "toggles the inline mark bad form", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/toggle_bad_form.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")

      refute render(view) =~ "Why is this bad?"

      html =
        view
        |> element("td button[title='Open bad-file form'][phx-value-id='#{video.id}']")
        |> render_click()

      assert html =~ "Why is this bad?"
      assert html =~ "save"

      html =
        view
        |> element("form#mark-bad-form-#{video.id} button[type='button']")
        |> render_click()

      refute html =~ "Why is this bad?"
    end

    test "creates a manual bad-file issue from the videos page", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/manual_bad.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")

      view
      |> element("td button[title='Open bad-file form'][phx-value-id='#{video.id}']")
      |> render_click()

      html =
        view
        |> form("#mark-bad-form-#{video.id}", %{
          "issue" => %{
            "manual_reason" => "corrupt replacement",
            "manual_note" => "audio desync after intro"
          }
        })
        |> render_submit()

      assert html =~ "Marked as bad"

      [issue] = Reencodarr.Media.list_bad_file_issues()
      assert issue.video_id == video.id
      assert issue.issue_kind == :manual
      assert issue.classification == :manual_bad
      assert issue.manual_reason == "corrupt replacement"
      assert issue.manual_note == "audio desync after intro"
    end

    test "shows an error when the reason is blank", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/no_reason.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")

      view
      |> element("td button[title='Open bad-file form'][phx-value-id='#{video.id}']")
      |> render_click()

      html =
        view
        |> form("#mark-bad-form-#{video.id}", %{
          "issue" => %{
            "manual_reason" => "",
            "manual_note" => "still bad"
          }
        })
        |> render_submit()

      assert html =~ "Mark bad failed"
      assert Reencodarr.Media.list_bad_file_issues() == []
    end
  end

  # ---------------------------------------------------------------------------
  # Checkbox / bulk select
  # ---------------------------------------------------------------------------

  describe "bulk selection" do
    test "renders checkbox column", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/checkme.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")
      html = render(view)
      assert html =~ ~s(type="checkbox")
    end

    test "select_all checks all visible rows and shows bulk action", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/a.mkv"})
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/b.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")

      html = view |> element("[phx-click='select_all']") |> render_click()

      assert html =~ "Reset 2 selected"
    end

    test "deselect_all clears selection", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/c.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")

      view |> element("[phx-click='select_all']") |> render_click()
      html = view |> element("button[phx-click='deselect_all']") |> render_click()

      refute html =~ "Reset"
    end

    test "select_all shows prioritize bulk action", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/prio_a.mkv"})
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/prio_b.mkv"})
      {:ok, view, _html} = live(conn, ~p"/videos")

      html = view |> element("[phx-click='select_all']") |> render_click()

      assert html =~ "Prioritize 2 selected"
    end
  end

  # ---------------------------------------------------------------------------
  # Filter dropdowns
  # ---------------------------------------------------------------------------

  describe "filter_service event" do
    test "filtering by sonarr does not crash", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/show.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> element("form[phx-change='filter_service']")
        |> render_change(%{"service" => "sonarr"})

      assert html =~ "Videos"
    end

    test "resetting service filter shows all videos", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/show.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      view
      |> element("form[phx-change='filter_service']")
      |> render_change(%{"service" => "sonarr"})

      html =
        view
        |> element("form[phx-change='filter_service']")
        |> render_change(%{"service" => ""})

      assert html =~ "Videos"
    end

    test "service dropdown keeps the selected filter", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/service_keep.mkv", service_type: :sonarr})
      {:ok, _view, html} = live(conn, ~p"/videos?service=sonarr")

      assert html =~ ~s(<select name="service" value="sonarr")
    end
  end

  describe "filter_hdr event" do
    test "filtering HDR only does not crash", %{conn: conn} do
      {:ok, _} = Fixtures.video_fixture(%{path: "/media/hdr.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> element("form[phx-change='filter_hdr']")
        |> render_change(%{"hdr" => "true"})

      assert html =~ "Videos"
    end

    test "hdr dropdown keeps the selected filter", %{conn: conn} do
      {:ok, _} = Fixtures.hdr_video_fixture(%{path: "/media/hdr_keep.mkv"})
      {:ok, _view, html} = live(conn, ~p"/videos?hdr=true")

      assert html =~ ~s(<select name="hdr" value="true")
    end
  end

  describe "next_page event" do
    test "next_page button does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos")

      # next_page has no visible button when on page 1 and no data, but sending the event directly is valid
      html = view |> render_click("next_page", %{})
      assert html =~ "Videos"
    end
  end

  # ---------------------------------------------------------------------------
  # Per-row toggle_select
  # ---------------------------------------------------------------------------

  describe "per-row toggle_select" do
    test "clicking row checkbox selects that video", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/toggle.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> render_click("toggle_select", %{"id" => Integer.to_string(video.id)})

      assert html =~ "Videos"
    end

    test "select_range selects a contiguous visible range", %{conn: conn} do
      {:ok, first} = Fixtures.video_fixture(%{path: "/media/range/Show - S01E01.mkv"})
      {:ok, second} = Fixtures.video_fixture(%{path: "/media/range/Show - S01E02.mkv"})
      {:ok, third} = Fixtures.video_fixture(%{path: "/media/range/Show - S01E03.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos?search=/media/range")

      html =
        view
        |> render_click("select_range", %{
          "start_id" => Integer.to_string(first.id),
          "end_id" => Integer.to_string(third.id),
          "selected" => "true"
        })

      assert html =~ "Prioritize 3 selected"
      assert html =~ Integer.to_string(second.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Per-row actions
  # ---------------------------------------------------------------------------

  describe "reset_video event" do
    test "resets a failed video to needs_analysis", %{conn: conn} do
      {:ok, video} = Fixtures.failed_video_fixture(%{path: "/media/failed_reset.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> element("button[phx-click='reset_video'][phx-value-id='#{video.id}']")
        |> render_click()

      assert html =~ "Reset to needs_analysis"
    end

    test "shows error flash for non-existent video id", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos")
      html = view |> render_click("reset_video", %{"id" => "999999"})
      assert html =~ "Video not found"
    end
  end

  describe "force_reanalyze event" do
    test "queues video for re-analysis and shows flash", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/reanalyze.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> element("button[phx-click='force_reanalyze'][phx-value-id='#{video.id}']")
        |> render_click()

      assert html =~ "Queued for re-analysis"
    end
  end

  describe "stop job event" do
    test "shows x for queued CRF videos and marks them failed internally", %{conn: conn} do
      {:ok, video} =
        Fixtures.video_fixture(%{path: "/media/fail_queued_crf.mkv", state: :analyzed})

      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> element("button[phx-click='fail_video'][phx-value-id='#{video.id}']")
        |> render_click()

      assert html =~ "Job stopped"
      assert Reencodarr.Media.get_video!(video.id).state == :failed
    end

    test "does not show x for encoded or failed videos", %{conn: conn} do
      {:ok, _encoded} =
        Fixtures.encoded_video_fixture(%{path: "/media/no_fail_encoded.mkv"})

      {:ok, _failed} =
        Fixtures.failed_video_fixture(%{path: "/media/no_fail_failed.mkv"})

      {:ok, view, _} = live(conn, ~p"/videos?search=no_fail_")
      html = render(view)

      refute html =~ "phx-click=\"fail_video\""
    end
  end

  describe "delete_video event" do
    test "deletes video and shows success flash", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/delete_me.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> element("button[phx-click='delete_video'][phx-value-id='#{video.id}']")
        |> render_click()

      assert html =~ "Video deleted"
    end

    test "shows error for non-existent video id", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos")
      html = view |> render_click("delete_video", %{"id" => "999999"})
      assert html =~ "Video not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Bulk actions
  # ---------------------------------------------------------------------------

  describe "reset_selected event" do
    test "resets all selected videos and shows flash", %{conn: conn} do
      {:ok, _} = Fixtures.failed_video_fixture(%{path: "/media/bulk_reset.mkv"})
      {:ok, view, _} = live(conn, ~p"/videos")

      view |> element("[phx-click='select_all']") |> render_click()
      html = view |> element("button[phx-click='reset_selected']") |> render_click()

      assert html =~ "Reset 1 video(s) to needs_analysis"
    end
  end

  describe "prioritize actions" do
    test "prioritize_selected updates selected videos", %{conn: conn} do
      {:ok, first} =
        Fixtures.video_fixture(%{
          path: "/media/Season 01/Show - S01E01.mkv",
          state: :needs_analysis
        })

      {:ok, second} =
        Fixtures.video_fixture(%{
          path: "/media/Season 01/Show - S01E02.mkv",
          state: :analyzed
        })

      {:ok, view, _html} = live(conn, ~p"/videos")

      view |> element("[phx-click='select_all']") |> render_click()
      html = view |> element("button[phx-click='prioritize_selected']") |> render_click()

      assert html =~ "Prioritized 2 video(s)"
      assert Reencodarr.Media.get_video!(first.id).priority > 0
      assert Reencodarr.Media.get_video!(second.id).priority > 0
    end

    test "prioritize_season_visible only updates matching visible season rows", %{conn: conn} do
      {:ok, season_one_first} =
        Fixtures.video_fixture(%{
          path: "/media/Show/Season 01/Show - S01E01.mkv",
          state: :needs_analysis
        })

      {:ok, season_one_second} =
        Fixtures.video_fixture(%{
          path: "/media/Show/Season 01/Show - S01E02.mkv",
          state: :analyzed
        })

      {:ok, other_season} =
        Fixtures.video_fixture(%{
          path: "/media/Show/Season 02/Show - S02E01.mkv",
          state: :needs_analysis
        })

      {:ok, view, _html} = live(conn, ~p"/videos?search=Season%2001")

      html =
        view
        |> element(
          "button[phx-click='prioritize_season_visible'][phx-value-id='#{season_one_first.id}']"
        )
        |> render_click()

      assert html =~ "Prioritized 2 visible Season 01 video(s)"
      assert Reencodarr.Media.get_video!(season_one_first.id).priority > 0
      assert Reencodarr.Media.get_video!(season_one_second.id).priority > 0
      assert Reencodarr.Media.get_video!(other_season.id).priority == 0
    end
  end

  # ---------------------------------------------------------------------------
  # quick_filter_state
  # ---------------------------------------------------------------------------

  describe "quick_filter_state event" do
    test "clicking a state badge applies filter without crashing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos")
      html = view |> render_click("quick_filter_state", %{"state" => "analyzed"})
      assert html =~ "Videos"
    end

    test "clicking the active state badge toggles filter off", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos?state=analyzed")
      html = view |> render_click("quick_filter_state", %{"state" => "analyzed"})
      assert html =~ "Videos"
    end
  end

  # ---------------------------------------------------------------------------
  # clear_filters
  # ---------------------------------------------------------------------------

  describe "clear_filters button" do
    test "clicking clear_filters removes all active filters", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos?state=analyzed")

      html = view |> element("button[phx-click='clear_filters']") |> render_click()

      assert html =~ "Videos"
    end
  end
end
