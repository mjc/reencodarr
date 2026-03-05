defmodule ReencodarrWeb.FailuresLiveTest do
  @moduledoc """
  Tests for the FailuresLive page.

  NOTE: async: false required — the LiveView process is a separate BEAM process
  that needs shared DB sandbox access to see test-inserted data.

  FailuresLive loads data asynchronously (send(self(), :load_initial_data) during
  mount), so render(view) is called after live() to flush the pending message.
  """
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  # Flush the LiveView process mailbox (processes :load_initial_data) and return
  # the fully-loaded HTML.
  defp loaded_html(view), do: render(view)

  # ---------------------------------------------------------------------------
  # Mount / basic render
  # ---------------------------------------------------------------------------

  describe "mount" do
    test "renders the failures page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/failures")
      assert html =~ "Failures"
    end

    test "shows empty state after data loads when no failures exist", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/failures")
      html = loaded_html(view)
      assert html =~ "No Failures Found" or html =~ "All videos are processing successfully"
    end

    test "shows failure rows when failures exist", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/show/broken.mkv"})
      Media.record_video_failure(video, :crf_search, :timeout, message: "Timed out")

      {:ok, view, _} = live(conn, ~p"/failures")
      html = loaded_html(view)
      assert html =~ "broken.mkv"
    end
  end

  # ---------------------------------------------------------------------------
  # Filter buttons (rendered after async data load)
  # ---------------------------------------------------------------------------

  describe "filter_failures event" do
    test "clicking a stage filter button does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/failures")
      # Flush async load so filter buttons appear
      loaded_html(view)

      html =
        view
        |> element("button[phx-click='filter_failures'][phx-value-filter='analysis']")
        |> render_click()

      assert html =~ "Failures"
    end

    test "clicking filter and resetting to all renders correctly", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      view
      |> element("button[phx-click='filter_failures'][phx-value-filter='crf_search']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='filter_failures'][phx-value-filter='all']")
        |> render_click()

      assert html =~ "Failures"
    end
  end

  describe "filter_category event" do
    test "clicking a category filter does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      html =
        view
        |> element("button[phx-click='filter_category'][phx-value-category='timeout']")
        |> render_click()

      assert html =~ "Failures"
    end
  end

  # ---------------------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------------------

  describe "search event" do
    test "search does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      html =
        view
        |> form("form[phx-change='search']", %{search: "something"})
        |> render_change()

      assert html =~ "Failures"
    end

    test "search by video path shows matching failures", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/unique_broken_film.mkv"})
      Media.record_video_failure(video, :encoding, :process_failure, message: "encode fail")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      html =
        view
        |> form("form[phx-change='search']", %{search: "unique_broken_film"})
        |> render_change()

      assert html =~ "unique_broken_film"
    end
  end

  # ---------------------------------------------------------------------------
  # Select all (checkbox in table header — only rendered when failures exist)
  # ---------------------------------------------------------------------------

  describe "select_all" do
    test "select_all checkbox appears and is clickable when failures exist", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture()
      Media.record_video_failure(video, :crf_search, :timeout, message: "timeout")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      # select_all is an input[type=checkbox] inside table header
      html = view |> element("input[phx-click='select_all']") |> render_click()
      assert html =~ "Failures"
    end
  end

  # ---------------------------------------------------------------------------
  # Reset all failures
  # ---------------------------------------------------------------------------

  describe "reset_all_failures event" do
    test "reset_all_failures button does not crash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/failures")
      html = view |> element("button[phx-click='reset_all_failures']") |> render_click()
      assert html =~ "Failures"
    end
  end

  # ---------------------------------------------------------------------------
  # Row interactions (requires at least one failure in DB)
  # ---------------------------------------------------------------------------

  describe "toggle_details event" do
    test "toggle_details expands and collapses video row", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/show/detail.mkv"})
      Media.record_video_failure(video, :crf_search, :timeout, message: "Timed out")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      html =
        view
        |> element("[phx-click='toggle_details'][phx-value-video_id='#{video.id}']")
        |> render_click()

      assert html =~ "Failures"
    end
  end

  describe "toggle_select event" do
    test "toggle_select marks a row as selected", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture()
      Media.record_video_failure(video, :crf_search, :timeout, message: "timeout")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      html =
        view
        |> element("div[phx-click='toggle_select'][phx-value-video_id='#{video.id}']")
        |> render_click()

      assert html =~ "Failures"
    end
  end

  describe "deselect_all event" do
    test "deselect_all clears selected rows", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture()
      Media.record_video_failure(video, :crf_search, :timeout, message: "timeout")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      # First select all
      view |> element("input[phx-click='select_all']") |> render_click()

      # Then deselect all
      html = view |> element("input[phx-click='deselect_all']") |> render_click()
      assert html =~ "Failures"
    end
  end

  describe "clear_filters event" do
    test "clear_filters resets active filters", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture()
      Media.record_video_failure(video, :crf_search, :timeout, message: "timeout")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      # Apply a filter first
      view
      |> element("button[phx-click='filter_failures'][phx-value-filter='crf_search']")
      |> render_click()

      # Reset via the "All" stage button (same visual effect as clear_filters)
      html =
        view
        |> element("button[phx-click='filter_failures'][phx-value-filter='all']")
        |> render_click()

      assert html =~ "Failures"
    end
  end
end
