defmodule ReencodarrWeb.WorkersLiveTest do
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress
  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Fixtures

  setup do
    WorkerSessions.reset()
    :ok
  end

  test "renders an empty state when no workers are connected", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "Workers"
    assert html =~ "No workers connected."
    assert html =~ ~s(href="/workers")
  end

  test "shows the transfer panel when a restarted worker is receiving input", %{conn: conn} do
    {:ok, _session} =
      WorkerSessions.register(%{
        server_worker_id: "worker-server-1",
        client_worker_id: "worker-client-1",
        protocol_version: 1,
        version: "0.10.0",
        capabilities: %{"crf_search" => true}
      })

    {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

    assert {:ok, view, html} = live(conn, ~p"/workers")
    assert html =~ "worker-client-1"
    assert html =~ "Idle"
    refute html =~ "Receiving Input"

    assert {:ok, _session} =
             WorkerSessions.assign_video("worker-server-1", video.id, :receiving_input)

    assert :ok =
             WorkerSessions.touch("worker-server-1", %{
               cpu_percent: 87.5,
               memory_bytes: 1_073_741_824,
               memory_total_bytes: 4_294_967_296,
               disk_free_bytes: 536_870_912_000,
               disk_total_bytes: 1_099_511_627_776
             })

    assert :ok =
             WorkerSessions.set_transfer_progress("worker-server-1", %{
               job_id: "job-1",
               transfer_id: "job-1",
               filename: Path.basename(video.path),
               percent: 25.5,
               bytes_sent: 2_621_440,
               total_bytes: 10_485_760,
               bytes_per_second: 1_048_576,
               eta: 15,
               chunk_index: 2,
               total_chunks: 8
             })

    send(view.pid, {:worker_sessions_updated, %{sessions: WorkerSessions.list()}})
    html = render(view)
    assert html =~ "Receiving input"
    assert html =~ "Receiving Input"
    refute html =~ "CRF Search"
    assert html =~ Path.basename(video.path)
    assert html =~ "Target: 95 VMAF"
    assert html =~ "CPU 87.5%"
    assert html =~ "Mem 1.0 GiB / 4.0 GiB"
    assert html =~ "Disk 500.0 GiB free / 1.0 TiB"
    assert html =~ "2.5 MiB / 10.0 MiB"
    assert html =~ "Chunk 3 / 8"
    assert html =~ "25.5%"
    assert html =~ "ETA 15s"
    refute html =~ "CRF 28.0 -&gt; 95.4 VMAF"
  end

  test "shows HTTP transfer progress without chunk text", %{conn: conn} do
    {:ok, _session} =
      WorkerSessions.register(%{
        server_worker_id: "worker-server-http",
        client_worker_id: "worker-client-http",
        protocol_version: 1,
        version: "0.10.0",
        capabilities: %{"crf_search" => true}
      })

    {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

    assert {:ok, _session} =
             WorkerSessions.assign_video("worker-server-http", video.id, :receiving_input)

    assert :ok =
             WorkerSessions.set_transfer_progress("worker-server-http", %{
               job_id: "job-http",
               transfer_id: "job-http",
               filename: Path.basename(video.path),
               percent: 50.0,
               bytes_sent: 117_440_512,
               total_bytes: 234_881_024,
               bytes_per_second: 122_683_392,
               eta: 1,
               chunk_index: 0,
               total_chunks: 0
             })

    {:ok, view, _html} = live(conn, ~p"/workers")
    send(view.pid, {:worker_sessions_updated, %{sessions: WorkerSessions.list()}})

    html = render(view)
    assert html =~ "Receiving Input"
    assert html =~ "112.0 MiB / 224.0 MiB"
    assert html =~ "117.0 MiB/s"
    assert html =~ "ETA 1s"
    refute html =~ "Chunk"
  end

  test "transfer progress wins over stale crf progress in the worker card", %{conn: conn} do
    {:ok, _session} =
      WorkerSessions.register(%{
        server_worker_id: "worker-server-stale-crf",
        client_worker_id: "worker-client-stale-crf",
        protocol_version: 1,
        version: "0.10.0",
        capabilities: %{"crf_search" => true}
      })

    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

    assert {:ok, _session} =
             WorkerSessions.assign_video("worker-server-stale-crf", video.id)

    assert :ok =
             WorkerSessions.set_crf_search_progress(
               "worker-server-stale-crf",
               %CrfSearchProgress{
                 video_id: video.id,
                 percent: 62.0,
                 fps: 12.5,
                 eta: 90,
                 crf: 28.0,
                 sample_num: 3,
                 total_samples: 8
               }
             )

    assert :ok =
             WorkerSessions.set_transfer_progress("worker-server-stale-crf", %{
               job_id: Integer.to_string(video.id),
               transfer_id: Integer.to_string(video.id),
               video_id: video.id,
               filename: Path.basename(video.path),
               percent: 10.0,
               bytes_sent: 1_048_576,
               total_bytes: 10_485_760
             })

    {:ok, view, _html} = live(conn, ~p"/workers")
    send(view.pid, {:worker_sessions_updated, %{sessions: WorkerSessions.list()}})

    html = render(view)
    assert html =~ "Receiving Input"
    refute html =~ "CRF Search"
    refute html =~ "Sample 3/8 - CRF 28.0"
  end

  test "renders the crf search panel when only crf search is active", %{conn: conn} do
    {:ok, _session} =
      WorkerSessions.register(%{
        server_worker_id: "worker-server-2",
        client_worker_id: "worker-client-2",
        protocol_version: 1,
        version: "0.10.0",
        capabilities: %{"crf_search" => true}
      })

    job_id = "crf-workers-page"

    {:ok, video} =
      Fixtures.video_fixture(%{
        state: :crf_searching,
        crf_search_worker_id: "worker-client-2",
        worker_attempt_id: job_id,
        worker_control_desired_state: :running,
        worker_control_acknowledged_state: :running
      })

    assert {:ok, _session} =
             WorkerSessions.assign_video(
               "worker-server-2",
               video.id,
               :crf_searching,
               job_id
             )

    assert :ok =
             WorkerSessions.set_crf_search_progress("worker-server-2", %CrfSearchProgress{
               job_id: job_id,
               video_id: video.id,
               percent: 62.0,
               fps: 12.5,
               eta: 90,
               crf: 28.0,
               sample_num: 3,
               total_samples: 8
             })

    Fixtures.vmaf_fixture(%{
      video_id: video.id,
      crf: 28.0,
      score: 95.4,
      percent: 93.0
    })

    {:ok, view, _html} = live(conn, ~p"/workers")
    send(view.pid, {:worker_sessions_updated, %{sessions: WorkerSessions.list()}})

    html = render(view)
    assert html =~ "CRF Search"
    assert html =~ "Sample 3/8 - CRF 28.0"
    assert html =~ "CRF 28.0 -&gt; 95.4 VMAF"
    refute html =~ "Receiving Input"

    Phoenix.PubSub.subscribe(
      Reencodarr.PubSub,
      ReencodarrWeb.WorkerChannel.worker_control_topic("worker-server-2")
    )

    view
    |> element(
      ~s(#crf-worker-worker-server-2 button[phx-click="pause_worker_crf_search"][phx-value-job-id="#{job_id}"])
    )
    |> render_click()

    assert_receive {:worker_control, :pause, ^job_id, command_id}
    assert is_binary(command_id)
    assert has_element?(view, "#crf-worker-worker-server-2", "Awaiting ACK")

    Fixtures.vmaf_fixture(%{video_id: video.id, crf: 26.0, score: 96.1, percent: 91.0})
    send(view.pid, {:crf_search_vmaf_result, %{video_id: video.id}})

    assert render(view) =~ "CRF 26.0 -&gt; 96.1 VMAF"
  end

  test "rejects a stale CRF control without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workers")

    assert render_hook(view, "pause_worker_crf_search", %{"worker-id" => "stale-worker"}) =~
             "Worker job is no longer available"

    assert Process.alive?(view.pid)
  end

  test "renders a start control for a stopped worker", %{conn: conn} do
    assert {:ok, _session} =
             WorkerSessions.register(%{
               server_worker_id: "worker-server-stopped",
               client_worker_id: "worker-client-stopped",
               protocol_version: 1,
               version: "0.10.0",
               capabilities: %{"crf_search" => true}
             })

    assert {:ok, _session} =
             WorkerSessions.set_control_state("worker-server-stopped", :stopped)

    {:ok, view, _html} = live(conn, ~p"/workers")
    html = render(view)

    assert html =~ "Stopped"
    assert html =~ "Start"
    assert has_element?(view, "button[phx-click=start_worker_crf_search]")
  end

  test "shows input ready after input transfer finishes before CRF progress", %{conn: conn} do
    {:ok, _session} =
      WorkerSessions.register(%{
        server_worker_id: "worker-server-3",
        client_worker_id: "worker-client-3",
        protocol_version: 1,
        version: "0.10.0",
        capabilities: %{"crf_search" => true}
      })

    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

    assert {:ok, _session} =
             WorkerSessions.assign_video("worker-server-3", video.id, :receiving_input)

    assert :ok =
             WorkerSessions.set_transfer_progress("worker-server-3", %{
               job_id: Integer.to_string(video.id),
               video_id: video.id,
               transfer_id: Integer.to_string(video.id),
               filename: Path.basename(video.path),
               percent: 100.0,
               bytes_sent: video.size,
               total_bytes: video.size
             })

    assert {:ok, _session} = WorkerSessions.finish_transfer("worker-server-3")

    {:ok, view, _html} = live(conn, ~p"/workers")
    send(view.pid, {:worker_sessions_updated, %{sessions: WorkerSessions.list()}})

    html = render(view)
    assert html =~ "worker-client-3"
    assert html =~ "Input ready"
    assert html =~ "Input Ready"
    refute html =~ "CRF Search"
    refute html =~ "-%"
  end
end
