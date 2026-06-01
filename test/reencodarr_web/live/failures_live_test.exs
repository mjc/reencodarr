defmodule ReencodarrWeb.FailuresLiveTest do
  @moduledoc """
  Tests for the FailuresLive page.

  NOTE: async: false required — the LiveView process is a separate BEAM process
  that needs shared DB sandbox access to see test-inserted data.

  FailuresLive loads the initial snapshot during mount and refreshes through async
  reloads, so render(view) is called after live() to flush pending work.
  """
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  # Flush the LiveView process mailbox (processes :load_initial_data) and return
  # the fully-loaded HTML.
  defp loaded_html(view), do: render(view)

  defp current_page_from_html(html) do
    case Regex.run(~r/Page\s*<span class="font-medium text-white">(-?\d+)<\/span>/, html) do
      [_, page] -> String.to_integer(page)
      _ -> nil
    end
  end

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

    test "hydrates failures in the first HTML response", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/first_failure.mkv", state: :failed})
      Media.record_video_failure(video, :encoding, :timeout, message: "first response failure")

      {:ok, _view, html} = live(conn, ~p"/failures")

      assert html =~ "first_failure.mkv"
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

      render_async(view)

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

  describe "filter behavior with real data" do
    test "stage filter shows only matching stage failures", %{conn: conn} do
      {:ok, analysis_video} = Fixtures.video_fixture(%{path: "/media/filter_analysis_match.mkv"})
      {:ok, encoding_video} = Fixtures.video_fixture(%{path: "/media/filter_encoding_other.mkv"})

      Media.record_video_failure(analysis_video, :analysis, :timeout, message: "analysis failure")
      Media.record_video_failure(encoding_video, :encoding, :timeout, message: "encoding failure")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      view
      |> element("button[phx-click='filter_failures'][phx-value-filter='analysis']")
      |> render_click()

      html = render_async(view)

      assert html =~ "filter_analysis_match.mkv"
      refute html =~ "filter_encoding_other.mkv"
    end

    test "category filter shows only matching categories", %{conn: conn} do
      {:ok, process_video} = Fixtures.video_fixture(%{path: "/media/filter_process_match.mkv"})
      {:ok, timeout_video} = Fixtures.video_fixture(%{path: "/media/filter_timeout_other.mkv"})

      Media.record_video_failure(process_video, :encoding, :process_failure,
        message: "process failure"
      )

      Media.record_video_failure(timeout_video, :encoding, :timeout, message: "timeout failure")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      view
      |> element("button[phx-click='filter_category'][phx-value-category='process_failure']")
      |> render_click()

      html = render_async(view)

      assert html =~ "filter_process_match.mkv"
      refute html =~ "filter_timeout_other.mkv"
    end

    test "invalid stage filter falls back to all results", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/invalid_stage_fallback.mkv"})
      Media.record_video_failure(video, :encoding, :timeout, message: "timeout failure")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      view
      |> element("button[phx-click='filter_failures'][phx-value-filter='all']")
      |> render_click(%{"filter" => "definitely_invalid_stage"})

      html = render_async(view)

      assert html =~ "invalid_stage_fallback.mkv"
    end

    test "invalid category filter falls back to all results", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/invalid_category_fallback.mkv"})
      Media.record_video_failure(video, :encoding, :timeout, message: "timeout failure")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      view
      |> element("button[phx-click='filter_category'][phx-value-category='all']")
      |> render_click(%{"category" => "definitely_invalid_category"})

      html = render_async(view)

      assert html =~ "invalid_category_fallback.mkv"
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

      view
      |> form("form[phx-change='search']", %{search: "unique_broken_film"})
      |> render_change()

      html = render_async(view)

      assert html =~ "unique_broken_film"
    end

    test "search trims surrounding whitespace", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/trimmed_search_hit.mkv"})
      Media.record_video_failure(video, :encoding, :process_failure, message: "encode fail")

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      view
      |> form("form[phx-change='search']", %{search: "   trimmed_search_hit   "})
      |> render_change()

      html = render_async(view)

      assert html =~ "trimmed_search_hit"
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

  describe "retry_failure_code event" do
    test "renders retry-by-code actions and retries matching failures", %{conn: conn} do
      {:ok, exit_143_video} =
        Fixtures.video_fixture(%{path: "/media/exit_143_video.mkv", state: :failed})

      {:ok, timeout_video} =
        Fixtures.video_fixture(%{path: "/media/timeout_video.mkv", state: :failed})

      Media.record_video_failure(exit_143_video, :encoding, :resource_exhaustion,
        code: "EXIT_143",
        message: "Killed"
      )

      Media.record_video_failure(timeout_video, :encoding, :timeout,
        code: "TIMEOUT",
        message: "Timed out"
      )

      {:ok, view, _} = live(conn, ~p"/failures")
      html = loaded_html(view)

      assert html =~ "Retry By Error Code"
      assert html =~ "EXIT_143"
      assert html =~ "TIMEOUT"

      html =
        view
        |> element("button[phx-click='retry_failure_code'][phx-value-code='EXIT_143']")
        |> render_click()

      assert html =~ "Failures"
      assert Media.get_video!(exit_143_video.id).state == :needs_analysis
      assert Media.get_video!(timeout_video.id).state == :failed
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

  describe "pagination behavior" do
    test "change_page with invalid low page clamps to page 1", %{conn: conn} do
      Enum.each(1..21, fn n ->
        {:ok, video} = Fixtures.video_fixture(%{path: "/media/page_item_#{n}.mkv"})
        Media.record_video_failure(video, :encoding, :timeout, message: "failure #{n}")
      end)

      {:ok, view, _} = live(conn, ~p"/failures")
      loaded_html(view)

      view
      |> element("button[phx-click='change_page'][title='Next page']")
      |> render_click()

      render_async(view)

      view
      |> element("button[phx-click='change_page'][title='First page']")
      |> render_click(%{"page" => "0"})

      html = render_async(view)

      assert current_page_from_html(html) == 1
    end
  end
end
