defmodule ReencodarrWeb.BadFilesLiveTest do
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.BadFileRemediation
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  setup do
    :meck.unload()
    :ok
  end

  describe "mount" do
    test "renders the bad files page with listed issues", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/bad_queue.mkv"})

      {:ok, _issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "wrong release group",
          manual_note: "known bad import"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      html = render_async(view)

      assert html =~ "Bad Files"
      assert html =~ "wrong release group"
      assert html =~ "bad_queue.mkv"
    end

    test "renders status summary and separates active from resolved issues", %{conn: conn} do
      {:ok, active_video} = Fixtures.video_fixture(%{path: "/media/active_issue.mkv"})
      {:ok, resolved_video} = Fixtures.video_fixture(%{path: "/media/resolved_issue.mkv"})

      {:ok, active_issue} =
        Media.create_bad_file_issue(active_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "active problem"
        })

      {:ok, resolved_issue} =
        Media.create_bad_file_issue(resolved_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "resolved problem"
        })

      {:ok, _queued_issue} = Media.enqueue_bad_file_issue(active_issue)
      {:ok, _clean_issue} = Media.update_bad_file_issue_status(resolved_issue, :replaced_clean)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      html = render_async(view)

      assert html =~ "Open: 0"
      assert html =~ "Queued: 1"
      assert html =~ "Resolved: 1"
      assert html =~ "Active Issues"
      assert html =~ "Resolved Issues"
      assert html =~ "active_issue.mkv"
      refute html =~ "resolved_issue.mkv"

      view |> element("#toggle-resolved-issues") |> render_click()
      html = render_async(view)
      assert html =~ "resolved_issue.mkv"
    end

    test "renders generic metadata for audit issues without special-casing audio", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/audio_issue.mkv"})

      {:ok, _issue} =
        Media.create_bad_file_issue(video, %{
          origin: :audit,
          issue_kind: :audio,
          classification: :confirmed_bad_audio_layout,
          source_audio_codec: "E-AC-3",
          source_channels: 6,
          source_layout: "5.1(side)",
          output_audio_codec: "Opus",
          output_channels: 6,
          output_layout: "5.1"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      html = render_async(view)

      assert html =~ "confirmed_bad_audio_layout"
      assert html =~ "audio"
      assert html =~ "audio_issue.mkv"
    end
  end

  describe "issue actions" do
    test "enqueue updates status to queued", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/enqueue_bad.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "bad mux"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#enqueue-issue-#{issue.id}") |> render_click()

      assert html =~ "Queued bad-file issue"
      assert Media.get_bad_file_issue!(issue.id).status == :queued
    end

    test "dismiss updates status to dismissed", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/dismiss_bad.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "damaged rip"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#dismiss-issue-#{issue.id}") |> render_click()

      assert html =~ "Dismissed bad-file issue"
      assert Media.get_bad_file_issue!(issue.id).status == :dismissed
    end

    test "retry moves failed issues back to queued", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/retry_bad.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "still bad"
        })

      {:ok, failed_issue} = Media.update_bad_file_issue_status(issue, :failed)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#retry-issue-#{failed_issue.id}") |> render_click()

      assert html =~ "Re-queued bad-file issue"
      assert Media.get_bad_file_issue!(failed_issue.id).status == :queued
    end

    test "replace now processes only the selected issue", %{conn: conn} do
      {:ok, selected_video} =
        Fixtures.video_fixture(%{path: "/shows/Show/Season 01/selected.mkv"})

      {:ok, other_video} = Fixtures.video_fixture(%{path: "/shows/Show/Season 01/other.mkv"})

      {:ok, selected_issue} =
        Media.create_bad_file_issue(selected_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "selected"
        })

      {:ok, other_issue} =
        Media.create_bad_file_issue(other_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "other"
        })

      :meck.new(BadFileRemediation, [:passthrough])

      :meck.expect(BadFileRemediation, :process_issue, fn issue, [] ->
        assert issue.id == selected_issue.id
        Media.update_bad_file_issue_status(issue, :waiting_for_replacement)
      end)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#replace-issue-now-#{selected_issue.id}") |> render_click()

      assert html =~ "Started replacement for selected issue"
      assert Media.get_bad_file_issue!(selected_issue.id).status == :waiting_for_replacement
      assert Media.get_bad_file_issue!(other_issue.id).status == :open
    end

    test "replace next queued processes one queued issue", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/queued_replace.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "replace me"
        })

      {:ok, _queued_issue} = Media.enqueue_bad_file_issue(issue)

      :meck.new(BadFileRemediation, [:passthrough])

      :meck.expect(BadFileRemediation, :process_next_issue, fn [] ->
        {:ok, Media.get_bad_file_issue!(issue.id)}
      end)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#replace-next-queued") |> render_click()

      assert html =~ "Started replacement for next queued bad file"
    end

    test "replace next by service only processes the matching queued lane", %{conn: conn} do
      {:ok, sonarr_video} =
        Fixtures.video_fixture(%{path: "/media/queued_sonarr_replace.mkv", service_type: :sonarr})

      {:ok, radarr_video} =
        Fixtures.video_fixture(%{path: "/media/queued_radarr_replace.mkv", service_type: :radarr})

      {:ok, sonarr_issue} =
        Media.create_bad_file_issue(sonarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "tv"
        })

      {:ok, radarr_issue} =
        Media.create_bad_file_issue(radarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "movie"
        })

      {:ok, _queued_sonarr_issue} = Media.enqueue_bad_file_issue(sonarr_issue)
      {:ok, _queued_radarr_issue} = Media.enqueue_bad_file_issue(radarr_issue)

      :meck.new(BadFileRemediation, [:passthrough])

      :meck.expect(BadFileRemediation, :process_next_issue, fn [service_type: :sonarr] ->
        {:ok, Media.get_bad_file_issue!(sonarr_issue.id)}
      end)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#replace-next-sonarr") |> render_click()

      assert html =~ "Started replacement for next queued sonarr bad file"
      refute html =~ "Started replacement for next queued radarr bad file"
      assert Media.get_bad_file_issue!(radarr_issue.id).status == :queued
    end

    test "replace queued now starts one queued issue per service", %{conn: conn} do
      {:ok, sonarr_video} =
        Fixtures.video_fixture(%{path: "/media/bulk_replace_sonarr.mkv", service_type: :sonarr})

      {:ok, radarr_video} =
        Fixtures.video_fixture(%{path: "/media/bulk_replace_radarr.mkv", service_type: :radarr})

      {:ok, sonarr_issue} =
        Media.create_bad_file_issue(sonarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "tv"
        })

      {:ok, radarr_issue} =
        Media.create_bad_file_issue(radarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "movie"
        })

      {:ok, _queued_sonarr_issue} = Media.enqueue_bad_file_issue(sonarr_issue)
      {:ok, _queued_radarr_issue} = Media.enqueue_bad_file_issue(radarr_issue)

      :meck.new(BadFileRemediation, [:passthrough])

      :meck.expect(BadFileRemediation, :process_next_issue, fn
        [service_type: :sonarr] -> {:ok, Media.get_bad_file_issue!(sonarr_issue.id)}
        [service_type: :radarr] -> {:ok, Media.get_bad_file_issue!(radarr_issue.id)}
      end)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#replace-queued-now") |> render_click()

      assert html =~ "Started replacement for 2 queued bad files"
    end

    test "queue filtered queues all currently filtered issues", %{conn: conn} do
      {:ok, first_video} =
        Fixtures.video_fixture(%{path: "/media/filter_bulk_one.mkv", service_type: :sonarr})

      {:ok, second_video} =
        Fixtures.video_fixture(%{path: "/media/filter_bulk_two.mkv", service_type: :sonarr})

      {:ok, third_video} =
        Fixtures.video_fixture(%{path: "/media/filter_bulk_movie.mkv", service_type: :radarr})

      {:ok, first_issue} =
        Media.create_bad_file_issue(first_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "manual"
        })

      {:ok, second_issue} =
        Media.create_bad_file_issue(second_video, %{
          origin: :audit,
          issue_kind: :audio,
          classification: :confirmed_bad_audio_layout
        })

      {:ok, third_issue} =
        Media.create_bad_file_issue(third_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "movie"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)

      _html =
        view
        |> form("#bad-files-service-filter", %{"service" => "sonarr"})
        |> render_change()

      html = view |> element("#queue-filtered-issues") |> render_click()

      assert html =~ "Queued 2 filtered bad-file issues"
      assert Media.get_bad_file_issue!(first_issue.id).status == :queued
      assert Media.get_bad_file_issue!(second_issue.id).status == :queued
      assert Media.get_bad_file_issue!(third_issue.id).status == :open
    end

    test "replace filtered now queues filtered issues and starts one per service", %{conn: conn} do
      {:ok, sonarr_video} =
        Fixtures.video_fixture(%{path: "/media/replace_filtered_tv.mkv", service_type: :sonarr})

      {:ok, radarr_video} =
        Fixtures.video_fixture(%{
          path: "/media/replace_filtered_movie.mkv",
          service_type: :radarr
        })

      {:ok, other_video} =
        Fixtures.video_fixture(%{
          path: "/media/replace_filtered_other.mkv",
          service_type: :radarr
        })

      {:ok, sonarr_issue} =
        Media.create_bad_file_issue(sonarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "tv"
        })

      {:ok, radarr_issue} =
        Media.create_bad_file_issue(radarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "movie"
        })

      {:ok, other_issue} =
        Media.create_bad_file_issue(other_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "other movie"
        })

      :meck.new(BadFileRemediation, [:passthrough])

      :meck.expect(BadFileRemediation, :process_next_issue, fn
        [service_type: :sonarr] -> {:ok, Media.get_bad_file_issue!(sonarr_issue.id)}
        [service_type: :radarr] -> {:ok, Media.get_bad_file_issue!(radarr_issue.id)}
      end)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)

      _html =
        view
        |> form("#bad-files-search-filter", %{"query" => "replace_filtered"})
        |> render_change()

      html = view |> element("#replace-filtered-now") |> render_click()

      assert html =~ "Queued 3 filtered bad-file issues and started 2 replacements"
      assert Media.get_bad_file_issue!(sonarr_issue.id).status == :queued
      assert Media.get_bad_file_issue!(radarr_issue.id).status == :queued
      assert Media.get_bad_file_issue!(other_issue.id).status == :queued
    end

    test "queue series bad only queues already-bad issues from the same series", %{conn: conn} do
      {:ok, target_video} =
        Fixtures.video_fixture(%{
          path: "/shows/Series Name/Season 01/episode1.mkv",
          service_type: :sonarr
        })

      {:ok, same_series_video} =
        Fixtures.video_fixture(%{
          path: "/shows/Series Name/Season 02/episode2.mkv",
          service_type: :sonarr
        })

      {:ok, different_series_video} =
        Fixtures.video_fixture(%{
          path: "/shows/Other Series/Season 01/episode3.mkv",
          service_type: :sonarr
        })

      {:ok, target_issue} =
        Media.create_bad_file_issue(target_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "bad ep1"
        })

      {:ok, same_series_issue} =
        Media.create_bad_file_issue(same_series_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "bad ep2"
        })

      {:ok, different_series_issue} =
        Media.create_bad_file_issue(different_series_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "other show"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)
      html = view |> element("#queue-series-issues-#{target_issue.id}") |> render_click()

      assert html =~ "Queued 2 bad files from this series"
      assert Media.get_bad_file_issue!(target_issue.id).status == :queued
      assert Media.get_bad_file_issue!(same_series_issue.id).status == :queued
      assert Media.get_bad_file_issue!(different_series_issue.id).status == :open
    end

    test "refreshes through the existing dashboard event channel", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/external-update.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "needs replacement"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      html = render_async(view)
      assert html =~ "open"

      {:ok, _updated_issue} = Media.update_bad_file_issue_status(issue, :replaced_clean)
      Events.broadcast_event(:sync_completed, %{service_type: :sonarr})

      html = render_async(view)
      assert html =~ "Resolved: 1"
      refute html =~ "external-update.mkv"
    end
  end

  describe "filters" do
    test "filters issues by status", %{conn: conn} do
      {:ok, open_video} = Fixtures.video_fixture(%{path: "/media/filter_open.mkv"})
      {:ok, queued_video} = Fixtures.video_fixture(%{path: "/media/filter_queued.mkv"})

      {:ok, _open_issue} =
        Media.create_bad_file_issue(open_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "open issue"
        })

      {:ok, queued_issue} =
        Media.create_bad_file_issue(queued_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "queued issue"
        })

      {:ok, _queued_issue} = Media.enqueue_bad_file_issue(queued_issue)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)

      view
      |> form("#bad-files-status-filter", %{"status" => "queued"})
      |> render_change()

      assert_patch(view, ~p"/bad-files?page=1&per_page=50&status=queued")
      html = render_async(view)
      assert html =~ "filter_queued.mkv"
      refute html =~ "filter_open.mkv"
    end

    test "filters issues by service type", %{conn: conn} do
      {:ok, sonarr_video} =
        Fixtures.video_fixture(%{path: "/media/filter_sonarr.mkv", service_type: :sonarr})

      {:ok, radarr_video} =
        Fixtures.video_fixture(%{path: "/media/filter_radarr.mkv", service_type: :radarr})

      {:ok, _sonarr_issue} =
        Media.create_bad_file_issue(sonarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "tv issue"
        })

      {:ok, _radarr_issue} =
        Media.create_bad_file_issue(radarr_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "movie issue"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)

      view
      |> form("#bad-files-service-filter", %{"service" => "radarr"})
      |> render_change()

      assert_patch(view, ~p"/bad-files?page=1&per_page=50&service=radarr")
      html = render_async(view)
      assert html =~ "filter_radarr.mkv"
      refute html =~ "filter_sonarr.mkv"
    end

    test "filters issues by issue kind", %{conn: conn} do
      {:ok, manual_video} = Fixtures.video_fixture(%{path: "/media/filter_manual_kind.mkv"})
      {:ok, audio_video} = Fixtures.video_fixture(%{path: "/media/filter_audio_kind.mkv"})

      {:ok, _manual_issue} =
        Media.create_bad_file_issue(manual_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "manual issue"
        })

      {:ok, _audio_issue} =
        Media.create_bad_file_issue(audio_video, %{
          origin: :audit,
          issue_kind: :audio,
          classification: :confirmed_bad_audio_layout
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)

      view
      |> form("#bad-files-kind-filter", %{"kind" => "audio"})
      |> render_change()

      assert_patch(view, ~p"/bad-files?kind=audio&page=1&per_page=50")
      html = render_async(view)
      assert html =~ "filter_audio_kind.mkv"
      refute html =~ "filter_manual_kind.mkv"
    end

    test "filters issues by search text across path and reason", %{conn: conn} do
      {:ok, first_video} = Fixtures.video_fixture(%{path: "/media/search_this_title.mkv"})
      {:ok, second_video} = Fixtures.video_fixture(%{path: "/media/other_title.mkv"})

      {:ok, _first_issue} =
        Media.create_bad_file_issue(first_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "desync problem"
        })

      {:ok, _second_issue} =
        Media.create_bad_file_issue(second_video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "blocky encode"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      render_async(view)

      view
      |> form("#bad-files-search-filter", %{"query" => "search_this"})
      |> render_change()

      assert_patch(view, ~p"/bad-files?page=1&per_page=50&search=search_this")
      by_path_html = render_async(view)
      assert by_path_html =~ "search_this_title.mkv"
      refute by_path_html =~ "other_title.mkv"

      view
      |> form("#bad-files-search-filter", %{"query" => "blocky"})
      |> render_change()

      assert_patch(view, ~p"/bad-files?page=1&per_page=50&search=blocky")
      by_reason_html = render_async(view)
      assert by_reason_html =~ "other_title.mkv"
      refute by_reason_html =~ "search_this_title.mkv"
    end
  end
end
