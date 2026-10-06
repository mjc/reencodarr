defmodule ReencodarrWeb.DashboardLayoutTest do
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.AbAv1.WorkerSessions.Job
  alias Reencodarr.Dashboard.State

  setup do
    previous = Application.get_env(:reencodarr, :crf_execution_mode)
    Application.put_env(:reencodarr, :crf_execution_mode, :worker)
    WorkerSessions.reset()

    on_exit(fn ->
      WorkerSessions.reset()

      if is_nil(previous),
        do: Application.delete_env(:reencodarr, :crf_execution_mode),
        else: Application.put_env(:reencodarr, :crf_execution_mode, previous)
    end)
  end

  test "separates server analysis from worker work and keeps setup out of the dashboard", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workflow-analyze", "Server")
    assert has_element?(view, "#workflow-crf-search", "Workers")
    assert has_element?(view, "#workflow-encode", "Workers")
    assert has_element?(view, "#dashboard-workers", "No workers connected")
    refute has_element?(view, "#dashboard-root", "Worker WebSocket")
    assert has_element?(view, "#app-settings a[href='/libraries']", "Library paths")
    assert has_element?(view, "#app-settings a[href='/rules']", "Encoding rules")
    refute has_element?(view, "#app-navigation > a[href='/libraries']")
  end

  test "groups concurrent jobs under their worker with separate controls", %{conn: conn} do
    {:ok, encode} = Fixtures.video_fixture(%{state: :encoding, path: "/media/encode.mkv"})
    {:ok, search} = Fixtures.video_fixture(%{state: :crf_searching, path: "/media/search.mkv"})
    register_worker()

    for {type, video} <- [encode: encode, crf_search: search] do
      {:ok, _session} =
        WorkerSessions.assign_job("server-atlas", %Job{
          job_id: "#{type}-#{video.id}",
          job_type: type,
          video_id: video.id,
          phase: if(type == :encode, do: :encoding, else: :crf_searching)
        })
    end

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#worker-atlas #encode-worker-atlas", "encode.mkv")
    assert has_element?(view, "#worker-atlas #crf-worker-atlas", "search.mkv")

    for {type, video} <- [encode: encode, crf_search: search] do
      assert has_element?(
               view,
               ~s(#worker-atlas button[phx-click="pause_worker_#{type}"][phx-value-job-id="#{type}-#{video.id}"])
             )
    end
  end

  test "idle workers do not show controls for inactive restored jobs", %{conn: conn} do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoding})
    register_worker()

    {:ok, _session} =
      WorkerSessions.assign_job("server-atlas", %Job{
        job_id: "restored",
        job_type: :encode,
        video_id: video.id,
        active: false
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#worker-atlas", "Idle")
    refute has_element?(view, "#worker-atlas button[phx-value-job-id='restored']")
  end

  test "switches the shared queue without duplicating it under workers", %{conn: conn} do
    {:ok, encode} =
      Fixtures.video_fixture(%{state: :crf_searched, path: "/media/queued-encode.mkv"})

    {:ok, search} = Fixtures.video_fixture(%{state: :analyzed, path: "/media/queued-search.mkv"})
    {:ok, view, _html} = live(conn, ~p"/")

    send(
      view.pid,
      {:dashboard_state_changed,
       %{
         State.get_state()
         | queue_counts: %{analyzer: 0, crf_searcher: 1, encoder: 1},
           queue_items: %{analyzer: [], crf_searcher: [search], encoder: [encode]}
       }}
    )

    assert has_element?(
             view,
             "#dashboard-queue button[aria-pressed='true'][phx-value-stage='encoder']"
           )

    assert has_element?(view, "#dashboard-queue", "queued-encode.mkv")
    refute has_element?(view, "#dashboard-queue", "queued-search.mkv")

    view
    |> element("button[phx-click='select_queue'][phx-value-stage='crf_searcher']")
    |> render_click()

    assert has_element?(
             view,
             "#dashboard-queue button[aria-pressed='true'][phx-value-stage='crf_searcher']"
           )

    assert has_element?(view, "#dashboard-queue", "queued-search.mkv")
    refute has_element?(view, "#dashboard-queue", "queued-encode.mkv")
    refute has_element?(view, "#dashboard-workers", "queued-search.mkv")
  end

  test "shows every active encode on the same worker", %{conn: conn} do
    register_worker()

    for name <- ["first", "second"] do
      {:ok, video} = Fixtures.video_fixture(%{state: :encoding, path: "/media/#{name}.mkv"})

      {:ok, _} =
        WorkerSessions.assign_job("server-atlas", %Job{
          job_id: name,
          job_type: :encode,
          video_id: video.id,
          phase: :encoding
        })
    end

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#worker-atlas", "first.mkv")
    assert has_element?(view, "#worker-atlas", "second.mkv")
    assert has_element?(view, "#worker-atlas button[phx-value-job-id='first']")
    assert has_element?(view, "#worker-atlas button[phx-value-job-id='second']")
  end

  test "shows CRF samples without presenting sample progress as overall completion", %{conn: conn} do
    register_worker()
    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

    :ok =
      WorkerSessions.set_crf_search_progress(
        "server-atlas",
        %Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress{
          job_id: "samples",
          video_id: video.id,
          percent: 62.0,
          crf: 30.0,
          sample_num: 4,
          total_samples: 8
        }
      )

    WorkerSessions.get("server-atlas")

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#crf-worker-atlas", "Sample 4/8")
    assert has_element?(view, "#crf-worker-atlas", "Testing CRF 30")
    refute has_element?(view, "#crf-worker-atlas progress[aria-label='Encode progress']")
    refute has_element?(view, "#crf-worker-atlas", "62.0%")
  end

  test "shows encoded files with actual savings in recent results", %{conn: conn} do
    {video, vmaf} =
      Fixtures.video_with_vmaf_fixture(
        %{
          state: :encoded,
          path: "/media/completed.mkv",
          space_saved_bytes: 4_294_967_296
        },
        %{score: 95.7}
      )

    Fixtures.choose_vmaf(video, vmaf)

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ".recent-encodes", "completed.mkv")
    assert has_element?(view, ".recent-encodes", "95.7")
    assert has_element?(view, ".recent-encodes", "4.0 GiB")
  end

  test "rejects removing an encoded file through stale queue controls", %{conn: conn} do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoded})
    {:ok, view, _} = live(conn, ~p"/")

    assert render_hook(view, "fail_queue_video", %{
             "id" => to_string(video.id),
             "stage" => "encoding"
           }) =~ "Unable to remove queued item"

    assert Reencodarr.Media.get_video(video.id).state == :encoded
  end

  test "keeps the dashboard available when recent encodes time out and retries", %{conn: conn} do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoded, path: "/media/recent.mkv"})
    :meck.new(Reencodarr.Media.VideoQueries, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Reencodarr.Media.VideoQueries) end)

    :meck.expect(Reencodarr.Media.VideoQueries, :recent_encodes, fn _, _ ->
      raise Exqlite.Error, message: "interrupted"
    end)

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#dashboard-workers")
    assert has_element?(view, ".recent-encodes", "Recent encodes unavailable")

    :meck.expect(Reencodarr.Media.VideoQueries, :recent_encodes, fn limit, opts ->
      :meck.passthrough([limit, opts])
    end)

    send(view.pid, :update_dashboard_data)
    assert has_element?(view, ".recent-encodes", "recent.mkv")

    :meck.expect(Reencodarr.Media.VideoQueries, :recent_encodes, fn _, _ ->
      raise DBConnection.ConnectionError, "connection not available"
    end)

    state = State.get_state()
    send(view.pid, {:dashboard_state_changed, %{state | stats: %{state.stats | encoded: 2}}})
    assert has_element?(view, ".recent-encodes", "recent.mkv")
    assert Reencodarr.Media.get_video(video.id).state == :encoded
  end

  defp register_worker do
    WorkerSessions.register(%{
      server_worker_id: "server-atlas",
      client_worker_id: "atlas",
      protocol_version: 1,
      version: "0.11.4",
      capabilities: %{"crf_search" => true, "encode" => true}
    })
  end
end
