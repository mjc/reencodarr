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
      {:ok, _view, html} = live(conn, ~p"/videos")
      # Table should still be present (no crash)
      assert html =~ "<table" or html =~ "No videos"
    end

    test "renders video rows when videos exist", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/show/ep01.mkv"})
      {:ok, _view, html} = live(conn, ~p"/videos")
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

      # The event pushes a patch — after render, the select should show "encoded" selected
      html = render(view)
      assert html =~ "selected"
    end

    test "filter_state renders the page without crashing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/videos")

      html =
        view
        |> form("form[phx-change='filter_state']", %{state: "encoded"})
        |> render_change()

      assert html =~ "Videos"
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
      {:ok, _view, html} = live(conn, ~p"/videos?q=preloaded")
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
      {:ok, _view, html} = live(conn, ~p"/videos?page=1")
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
  end

  # ---------------------------------------------------------------------------
  # VMAF badge
  # ---------------------------------------------------------------------------

  describe "vmaf badge" do
    test "shows em-dash when video has no chosen VMAF", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/no_vmaf.mkv"})
      {:ok, _view, html} = live(conn, ~p"/videos")
      assert html =~ "—"
    end

    test "renders score in green for VMAF >= 95", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/excellent.mkv"})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, score: 96.0})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, _view, html} = live(conn, ~p"/videos")
      assert html =~ "text-green-300"
      assert html =~ "96.0"
    end

    test "renders score in yellow for VMAF in [90, 95)", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/good.mkv"})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, score: 92.5})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, _view, html} = live(conn, ~p"/videos")
      assert html =~ "text-yellow-300"
      assert html =~ "92.5"
    end

    test "renders score in red for VMAF < 90", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/poor.mkv"})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, score: 85.0})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, _view, html} = live(conn, ~p"/videos")
      assert html =~ "text-red-400"
      assert html =~ "85.0"
    end
  end

  # ---------------------------------------------------------------------------
  # HDR badge
  # ---------------------------------------------------------------------------

  describe "hdr badge" do
    test "shows em-dash when video has no HDR", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/sdr.mkv", hdr: nil})
      {:ok, _view, html} = live(conn, ~p"/videos")
      assert html =~ "—"
    end

    test "renders HDR label in amber badge", %{conn: conn} do
      {:ok, _video} = Fixtures.hdr_video_fixture(%{path: "/media/hdr.mkv"})
      {:ok, _view, html} = live(conn, ~p"/videos")
      assert html =~ "HDR10"
      assert html =~ "bg-amber-900"
    end
  end

  # ---------------------------------------------------------------------------
  # Checkbox / bulk select
  # ---------------------------------------------------------------------------

  describe "bulk selection" do
    test "renders checkbox column", %{conn: conn} do
      {:ok, _video} = Fixtures.video_fixture(%{path: "/media/checkme.mkv"})
      {:ok, _view, html} = live(conn, ~p"/videos")
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
  end
end
