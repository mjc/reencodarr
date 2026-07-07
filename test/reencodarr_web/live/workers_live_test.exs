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

    send(view.pid, {:worker_sessions_updated, %{sessions: WorkerSessions.list()}})
    html = render(view)
    assert html =~ "analyzed"
    assert html =~ "video ##{video.id}"
  end
end
