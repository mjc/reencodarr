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

  test "renders connected worker details and refreshes on session updates", %{conn: conn} do
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

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", video.id)

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
               percent: 62.0,
               fps: 12.5,
               eta: 90
             })

    assert {:ok, _session} =
             WorkerSessions.set_transfer_progress("worker-server-1", %{
               percent: 25.5,
               chunk_index: 2,
               total_chunks: 8
             })

    Fixtures.vmaf_fixture(%{
      video_id: video.id,
      crf: 28.0,
      score: 95.4,
      percent: 93.0
    })

    send(view.pid, {:worker_sessions_updated, %{sessions: WorkerSessions.list()}})
    html = render(view)
    assert html =~ "analyzed"
    assert html =~ "video ##{video.id}"
    assert html =~ "CPU 87.5%"
    assert html =~ "Mem 1.0 GiB / 4.0 GiB"
    assert html =~ "Disk 500.0 GiB free / 1.0 TiB"
    assert html =~ "CRF 62.0%"
    assert html =~ "FPS 12.5 fps"
    assert html =~ "ETA 90s"
    assert html =~ "Transfer 25.5%"
    assert html =~ "Chunk 2"
    assert html =~ "CRF 28.0 -&gt; 95.4 (93.0%)"
  end
end
