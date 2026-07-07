defmodule Reencodarr.AbAv1.WorkerSessionsTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Diagnostics

  setup do
    WorkerSessions.reset()
    :ok
  end

  test "expires stale worker sessions" do
    assert {:ok, _session} =
             WorkerSessions.register(%{
               server_worker_id: "worker-server-1",
               client_worker_id: "worker-client-1",
               protocol_version: 1,
               version: "0.10.0",
               capabilities: %{"crf_search" => true}
             })

    assert [_session] = WorkerSessions.list()

    assert {:ok, expired_sessions} = WorkerSessions.expire_stale(0)
    assert Enum.map(expired_sessions, & &1.client_worker_id) == ["worker-client-1"]
    assert WorkerSessions.list() == []
  end

  test "timer-driven stale expiry removes old sessions" do
    previous_timeout = Application.get_env(:reencodarr, :worker_session_timeout_seconds)
    Application.put_env(:reencodarr, :worker_session_timeout_seconds, 0)

    on_exit(fn ->
      Application.put_env(:reencodarr, :worker_session_timeout_seconds, previous_timeout)
    end)

    assert {:ok, _session} =
             WorkerSessions.register(%{
               server_worker_id: "worker-server-1",
               client_worker_id: "worker-client-1",
               protocol_version: 1,
               version: "0.10.0",
               capabilities: %{"crf_search" => true}
             })

    send(Process.whereis(WorkerSessions), :expire_stale)
    :timer.sleep(25)

    assert WorkerSessions.list() == []
  end

  test "includes worker sessions in diagnostics output" do
    assert {:ok, _session} =
             WorkerSessions.register(%{
               server_worker_id: "worker-server-1",
               client_worker_id: "worker-client-1",
               protocol_version: 1,
               version: "0.10.0",
               capabilities: %{"crf_search" => true}
             })

    output = Diagnostics.processes()

    assert output =~ "Worker Sessions:"
    assert output =~ "worker-client-1"
    assert output =~ "protocol=1"
    assert output =~ "version=0.10.0"
  end

  test "tracks an assigned video on the session" do
    assert {:ok, _session} =
             WorkerSessions.register(%{
               server_worker_id: "worker-server-1",
               client_worker_id: "worker-client-1",
               protocol_version: 1,
               version: "0.10.0",
               capabilities: %{"crf_search" => true}
             })

    assert {:ok, session} = WorkerSessions.assign_video("worker-server-1", 123)
    assert session.active_video_id == 123

    [listed_session] = WorkerSessions.list()
    assert listed_session.active_video_id == 123
  end
end
