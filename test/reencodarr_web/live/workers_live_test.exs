defmodule ReencodarrWeb.WorkersLiveTest do
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.AbAv1.WorkerSessions

  setup do
    WorkerSessions.reset()
    :ok
  end

  test "renders an empty state when no workers are connected", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "Workers"
    assert html =~ "No workers connected."
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

    assert {:ok, view, html} = live(conn, ~p"/workers")
    assert html =~ "worker-client-1"
    assert html =~ "Idle"

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", 123)

    html = render(view)
    assert html =~ "Working"
    assert html =~ "video #123"
  end
end
