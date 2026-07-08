defmodule Reencodarr.AbAv1.WorkerSessionsTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Diagnostics
  alias Reencodarr.Fixtures
  alias Reencodarr.Media

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

  test "expires stale active sessions by requeueing only in-progress videos" do
    {:ok, active_video} = Fixtures.video_fixture(%{state: :crf_searching})
    {:ok, completed_video} = Fixtures.video_fixture(%{state: :crf_searched})
    _vmaf = Fixtures.vmaf_fixture(%{video_id: completed_video.id, crf: 28.0, score: 96.4})
    assert {:ok, _} = Media.mark_vmaf_as_chosen(completed_video.id, 28.0)

    assert {:ok, _session} =
             WorkerSessions.register(worker_session_attrs(server_worker_id: "worker-server-1"))

    assert {:ok, _session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-2",
                 client_worker_id: "worker-client-2"
               )
             )

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", active_video.id)
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-2", completed_video.id)

    assert {:ok, [_session_one, _session_two]} = WorkerSessions.expire_stale(0)
    assert Media.get_video(active_video.id).state == :analyzed
    assert Media.get_video(completed_video.id).state == :crf_searched
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

  test "keeps CRF sample metadata when later progress omits it" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, session} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %{
               video_id: 123,
               percent: 10.0,
               fps: 24.0,
               crf: 28.0,
               sample_num: 3,
               total_samples: 5
             })

    assert session.crf_search_progress.crf == 28.0
    assert session.crf_search_progress.sample_num == 3
    assert session.crf_search_progress.total_samples == 5

    assert {:ok, session} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %{
               video_id: 123,
               percent: 25.0,
               fps: 25.0,
               crf: nil,
               sample_num: nil,
               total_samples: nil
             })

    assert session.crf_search_progress.percent == 25.0
    assert session.crf_search_progress.fps == 25.0
    assert session.crf_search_progress.crf == 28.0
    assert session.crf_search_progress.sample_num == 3
    assert session.crf_search_progress.total_samples == 5
  end

  test "replaces reconnecting client sessions without dropping active state" do
    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

    assert {:ok, _session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-1",
                 client_worker_id: "worker-client-1"
               )
             )

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", video.id)

    assert {:ok, session} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %{
               video_id: video.id,
               percent: 25.0,
               fps: 24.0,
               crf: 28.0,
               sample_num: 2,
               total_samples: 5
             })

    assert session.active_video_id == video.id

    assert {:ok, session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-2",
                 client_worker_id: "worker-client-1"
               )
             )

    assert session.server_worker_id == "worker-server-2"
    assert session.client_worker_id == "worker-client-1"
    assert session.active_video_id == video.id
    assert session.crf_search_progress.video_id == video.id
    assert session.crf_search_progress.sample_num == 2
    assert is_nil(WorkerSessions.get("worker-server-1"))
  end

  test "does not preserve completed active state when replacing reconnecting sessions" do
    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
    _vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 28.0, score: 96.4})
    assert {:ok, _} = Media.mark_vmaf_as_chosen(video.id, 28.0)

    assert {:ok, _session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-1",
                 client_worker_id: "worker-client-1"
               )
             )

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", video.id)

    assert {:ok, _session} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %{
               video_id: video.id,
               percent: 100.0,
               fps: 24.0
             })

    assert {:ok, session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-2",
                 client_worker_id: "worker-client-1"
               )
             )

    assert is_nil(session.active_video_id)
    assert is_nil(session.crf_search_progress)
    assert Media.get_video(video.id).state == :crf_searched
  end

  test "cancels and drains active distributed work" do
    {:ok, video_one} = Fixtures.video_fixture(%{state: :analyzed})
    {:ok, video_two} = Fixtures.video_fixture(%{state: :analyzed})

    assert {:ok, _session} =
             WorkerSessions.register(worker_session_attrs(server_worker_id: "worker-server-1"))

    assert {:ok, _session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-2",
                 client_worker_id: "worker-client-2"
               )
             )

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", video_one.id)
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-2", video_two.id)

    assert {:ok, _session} = WorkerSessions.cancel("worker-server-1")
    assert Media.get_video(video_one.id).state == :analyzed

    assert {:ok, drained_sessions} = WorkerSessions.drain()
    assert Enum.map(drained_sessions, & &1.server_worker_id) == ["worker-server-2"]
    assert Media.get_video(video_two.id).state == :analyzed
    assert WorkerSessions.list() == []
  end

  test "cancel and drain do not reset completed videos" do
    {:ok, video_one} = Fixtures.video_fixture(%{state: :crf_searched})
    {:ok, video_two} = Fixtures.video_fixture(%{state: :crf_searched})
    _vmaf_one = Fixtures.vmaf_fixture(%{video_id: video_one.id, crf: 28.0, score: 96.4})
    _vmaf_two = Fixtures.vmaf_fixture(%{video_id: video_two.id, crf: 28.0, score: 96.4})
    assert {:ok, _} = Media.mark_vmaf_as_chosen(video_one.id, 28.0)
    assert {:ok, _} = Media.mark_vmaf_as_chosen(video_two.id, 28.0)

    assert {:ok, _session} =
             WorkerSessions.register(worker_session_attrs(server_worker_id: "worker-server-1"))

    assert {:ok, _session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-2",
                 client_worker_id: "worker-client-2"
               )
             )

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", video_one.id)
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-2", video_two.id)

    assert {:ok, _session} = WorkerSessions.cancel("worker-server-1")
    assert Media.get_video(video_one.id).state == :crf_searched

    assert {:ok, [_session]} = WorkerSessions.drain()
    assert Media.get_video(video_two.id).state == :crf_searched
    assert WorkerSessions.list() == []
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
