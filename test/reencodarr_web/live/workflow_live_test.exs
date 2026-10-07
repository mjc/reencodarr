defmodule ReencodarrWeb.WorkflowLiveTest do
  use ReencodarrWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ReencodarrWeb.AsyncLiveViewTestHelpers
  alias Reencodarr.{Fixtures, Media, Services}

  test "sources can be enabled directly and show sync progress instead of age", %{conn: conn} do
    config =
      Reencodarr.ServicesFixtures.config_fixture(%{service_type: :sportarr, enabled: false})

    {:ok, view, _} = live(conn, "/configs")
    assert has_element?(view, "#configs-#{config.id} button[role=switch][aria-checked=false]")
    view |> element("#configs-#{config.id} button[role=switch]") |> render_click()
    assert Services.get_config!(config.id).enabled
    assert has_element?(view, "#configs-#{config.id} button[role=switch][aria-checked=true]")
    send(view.pid, {:sync_progress, %{service_type: :sportarr, progress: 42}})
    assert has_element?(view, "#configs-#{config.id} progress[value='42']")
    assert has_element?(view, "#configs-#{config.id} button[phx-click=sync_source][disabled]")
    send(view.pid, {:sync_completed, %{service_type: :sportarr}})
    refute has_element?(view, "#configs-#{config.id} progress")
  end

  test "library paths expose the associated video count and a browse action", %{conn: conn} do
    library = Fixtures.library_fixture(%{path: "/media/library-test"})

    {:ok, _} =
      Fixtures.video_fixture(%{path: "/media/library-test/movie.mkv", library_id: library.id})

    {:ok, view, _} = live(conn, "/libraries")
    assert render_async(view) =~ "1 videos"
    assert has_element?(view, "#libraries-#{library.id} a", "View videos")
    refute has_element?(view, "input[name='library[monitor]']")
  end

  test "video inspection is bookmarkable and displays the chosen CRF", %{conn: conn} do
    {video, vmaf} = Fixtures.video_with_vmaf_fixture(%{path: "/media/inspect/video.mkv"})
    {:ok, video} = Media.update_video(video, %{chosen_vmaf_id: vmaf.id})
    {:ok, view, _} = live_loaded(conn, "/videos?video=#{video.id}")
    html = render_async(view)
    assert has_element?(view, "#video-inspection")
    assert html =~ "/media/inspect/video.mkv"
    assert html =~ "Chosen"
    assert html =~ "CRF #{vmaf.crf}"
  end

  test "Sportarr videos have a working filter and queue priority order", %{conn: conn} do
    {:ok, _} = Fixtures.video_fixture(%{service_type: :sportarr, path: "/sportarr/sport.mkv"})
    {:ok, _} = Fixtures.video_fixture(%{service_type: :radarr, path: "/movies/movie.mkv"})
    {:ok, _, html} = live_loaded(conn, "/videos?service=sportarr&sort_by=priority")
    assert html =~ "sport.mkv"
    refute html =~ "movie.mkv"
  end

  test "bad-file bulk actions only affect selected issues and filtering clears selection", %{
    conn: conn
  } do
    first = bad_issue("selected")
    other = bad_issue("untouched")
    {:ok, view, _} = live_loaded(conn, "/bad-files?status=review")
    view |> render_click("toggle_select", %{"id" => "#{first.id}"})
    view |> element("button[phx-click=queue_selected]") |> render_click()
    render_async(view)
    assert {:ok, %{status: :queued}} = Media.fetch_bad_file_issue(first.id)
    assert {:ok, %{status: :open}} = Media.fetch_bad_file_issue(other.id)

    view |> render_click("toggle_select", %{"id" => "#{other.id}"})
    view |> element("a[href='/bad-files?status=queued']") |> render_click()
    refute has_element?(view, "button[phx-click=dismiss_selected]")
    assert render_async(view) =~ "selected.mkv"
  end

  test "failure error code filters select the matching failures", %{conn: conn} do
    for {name, code} <- [{"timeout", "TIMEOUT"}, {"process", "PROCESS"}] do
      {:ok, video} = Fixtures.failed_video_fixture(%{path: "/failures/#{name}.mkv"})
      {:ok, _} = Media.record_video_failure(video, :encoding, :timeout, code: code, message: name)
    end

    {:ok, _, html} = live_loaded(conn, "/failures?code=TIMEOUT")
    assert html =~ "timeout.mkv"
    refute html =~ "process.mkv"
  end

  test "a replacement request leaves the page interactive and shows pending state", %{conn: conn} do
    alias Reencodarr.BadFileRemediation
    issue = bad_issue("async-request")
    parent = self()
    :meck.new(BadFileRemediation, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(BadFileRemediation) end)

    :meck.expect(BadFileRemediation, :process_issue, fn current, [] ->
      send(parent, {:replacement_request, self()})

      receive do
        :finish -> {:ok, current}
      after
        2_000 -> {:error, :timeout}
      end
    end)

    {:ok, view, _} = live_loaded(conn, "/bad-files")
    view |> element("#replace-issue-now-#{issue.id}") |> render_click()
    assert_receive {:replacement_request, task}
    assert has_element?(view, "[role=status]", "Sending replacement request")
    assert has_element?(view, "#replace-issue-now-#{issue.id}[disabled]")
    view |> render_click("toggle_select", %{"id" => "#{issue.id}"})
    assert has_element?(view, "button[phx-click=queue_selected]")
    send(task, :finish)
    assert render_async(view) =~ "Started replacement for selected issue"
    refute has_element?(view, "#replace-issue-now-#{issue.id}[disabled]")
  end

  defp bad_issue(name) do
    {:ok, video} = Fixtures.video_fixture(%{path: "/bad/#{name}.mkv"})

    {:ok, issue} =
      Media.create_bad_file_issue(video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: name
      })

    issue
  end
end
