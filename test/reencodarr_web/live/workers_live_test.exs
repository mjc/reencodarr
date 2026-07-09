defmodule ReencodarrWeb.WorkersLiveTest do
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

    assert {:ok, _session} =
             WorkerSessions.touch("worker-server-1", %{
               cpu_percent: 87.5,
               memory_bytes: 1_073_741_824,
               memory_total_bytes: 4_294_967_296,
               disk_free_bytes: 536_870_912_000,
               disk_total_bytes: 1_099_511_627_776
             })

    assert {:ok, _session} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %{
               video_id: video.id,
               percent: 62.0,
               fps: 12.5,
               eta: 90,
               crf: 28.0,
               sample_num: 3,
               total_samples: 8
             })

    assert {:ok, _session} =
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
    refute html =~ "Progress 62.0%"
    refute html =~ "FPS 12.5 fps"
    refute html =~ "Sample 3/8 - CRF 28.0"
    refute html =~ "CRF 28.0 -&gt; 95.4 VMAF"
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

    {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-2", video.id)

    assert {:ok, _session} =
             WorkerSessions.set_crf_search_progress("worker-server-2", %{
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
  end

  test "keeps the crf panel active after input transfer finishes", %{conn: conn} do
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

    assert {:ok, _session} =
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
    assert html =~ "crf_searching"
    assert html =~ "CRF Search"
    refute html =~ "Receiving Input"
    refute html =~ "-%"
  end
end
