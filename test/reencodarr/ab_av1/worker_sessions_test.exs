defmodule Reencodarr.AbAv1.WorkerSessionsTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Diagnostics
  alias Reencodarr.Fixtures

  setup do
    WorkerSessions.reset()
    :ok
  end

  test "rejects duplicate worker ids" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:error, :duplicate_worker_id} =
             WorkerSessions.register(worker_session_attrs(client_worker_id: "worker-client-2"))
  end

  test "returns unknown worker session for missing ids" do
    assert {:error, :unknown_worker_session} = WorkerSessions.touch("missing-worker")
    assert {:error, :unknown_worker_session} = WorkerSessions.assign_video("missing-worker", 123)
    assert {:error, :unknown_worker_session} = WorkerSessions.clear_video("missing-worker")
  end

  test "expires stale worker sessions" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

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

    Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    send(Process.whereis(WorkerSessions), :expire_stale)
    assert_receive {:worker_sessions_updated, %{sessions: []}}

    assert WorkerSessions.list() == []
  end

  test "includes worker sessions in diagnostics output" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())
    {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", video.id)

    output = Diagnostics.processes()

    assert output =~ "Worker Sessions:"
    assert output =~ "worker-client-1"
    assert output =~ "protocol=1"
    assert output =~ "version=0.10.0"
    assert output =~ "state=analyzed"
  end

  test "tracks an assigned video on the session" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, session} = WorkerSessions.assign_video("worker-server-1", 123)
    assert session.active_video_id == 123

    [listed_session] = WorkerSessions.list()
    assert listed_session.active_video_id == 123
  end

  defp worker_session_attrs(overrides \\ []) do
    %{
      server_worker_id: "worker-server-1",
      client_worker_id: "worker-client-1",
      protocol_version: 1,
      version: "0.10.0",
      capabilities: %{"crf_search" => true}
    }
    |> Map.merge(Map.new(overrides))
  end
end
