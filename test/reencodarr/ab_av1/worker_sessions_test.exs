defmodule Reencodarr.AbAv1.WorkerSessionsTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.WorkerProtocol.{CrfSearchProgress, EncodeProgress}
  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.AbAv1.WorkerSessions.Job
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
    assert {:error, :unknown_worker_session} = WorkerSessions.finish_transfer("missing-worker")
  end

  test "stopping a worker requeues active work without disconnecting its session" do
    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", video.id)

    assert {:ok, session} = WorkerSessions.set_control_state("worker-server-1", :stopped)
    assert session.control_state == :stopped
    assert session.phase == :idle
    assert is_nil(session.active_video_id)
    assert WorkerSessions.get("worker-server-1").client_worker_id == "worker-client-1"
    assert Media.get_video(video.id).state == :analyzed
  end

  test "tracks control state for an individual worker job" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, _session} =
             WorkerSessions.assign_job("worker-server-1", %Job{
               job_id: "encode-1",
               job_type: :encode,
               video_id: 1
             })

    assert {:ok, session} =
             WorkerSessions.set_job_control_state("worker-server-1", "encode-1", :paused)

    assert session.control_state == :running
    assert session.jobs["encode-1"].control_state == :paused
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

    {:ok, dispatched_video} =
      Fixtures.video_fixture(%{state: :crf_searching, crf_search_worker_id: "worker-client-3"})

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

    assert {:ok, _session} =
             WorkerSessions.register(
               worker_session_attrs(
                 server_worker_id: "worker-server-3",
                 client_worker_id: "worker-client-3"
               )
             )

    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", active_video.id)
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-2", completed_video.id)
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-3", dispatched_video.id)

    assert {:ok, [_session_one, _session_two, _session_three]} = WorkerSessions.expire_stale(0)
    assert Media.get_video(active_video.id).state == :analyzed
    assert Media.get_video(dispatched_video.id).state == :crf_searching
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
    assert output =~ "phase=crf_searching"
    assert output =~ "video_state=analyzed"
    assert output =~ "Local Worker Process:"
  end

  test "diagnostics identify worker execution mode without reporting Broadway as failed" do
    previous = Application.get_env(:reencodarr, :crf_execution_mode)
    previous_supervision = Application.get_env(:reencodarr, :supervise_local_worker)
    Application.put_env(:reencodarr, :crf_execution_mode, :worker)
    Application.put_env(:reencodarr, :supervise_local_worker, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:reencodarr, :crf_execution_mode)
      else
        Application.put_env(:reencodarr, :crf_execution_mode, previous)
      end

      if is_nil(previous_supervision) do
        Application.delete_env(:reencodarr, :supervise_local_worker)
      else
        Application.put_env(:reencodarr, :supervise_local_worker, previous_supervision)
      end
    end)

    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())
    output = Diagnostics.status()

    assert output =~ "CRF Searcher: mode=worker"
    assert output =~ "connected=1"
    assert output =~ "executor=independent"
    refute output =~ "CRF Searcher: mode=worker, connected=1, active=0, unavailable"
    refute output =~ "CRF Searcher: running=false"
  end

  test "tracks an assigned video on the session" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, session} = WorkerSessions.assign_video("worker-server-1", 123)
    assert session.active_video_id == 123
    assert session.phase == :crf_searching

    [listed_session] = WorkerSessions.list()
    assert listed_session.active_video_id == 123
    assert listed_session.phase == :crf_searching
  end

  test "complete transfer progress moves to input ready without clearing the active video" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, session} = WorkerSessions.assign_video("worker-server-1", 123, :receiving_input)
    assert session.active_video_id == 123
    assert session.phase == :receiving_input

    assert {:ok, session} =
             WorkerSessions.set_transfer_progress("worker-server-1", %{
               job_id: "job-1",
               video_id: 123,
               transfer_id: "job-1",
               filename: "sample.mkv",
               percent: 100.0,
               bytes_sent: 10_485_760,
               total_bytes: 10_485_760
             })

    assert session.active_video_id == 123
    assert session.phase == :input_ready
    assert session.transfer_progress.percent == 100.0

    assert {:ok, session} = WorkerSessions.finish_transfer("worker-server-1")
    assert session.active_video_id == 123
    assert session.phase == :input_ready
    assert session.transfer_progress.percent == 100.0
  end

  test "rejects progress for a different active video" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())
    assert {:ok, _session} = WorkerSessions.assign_video("worker-server-1", 123, :receiving_input)

    assert {:error, :invalid_worker_phase} =
             WorkerSessions.set_transfer_progress("worker-server-1", %{
               video_id: 456,
               percent: 25.0
             })

    assert {:error, :invalid_worker_phase} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %CrfSearchProgress{
               video_id: 456,
               percent: 25.0
             })

    session = WorkerSessions.get("worker-server-1")
    assert session.active_video_id == 123
    assert session.phase == :receiving_input
    assert is_nil(session.transfer_progress)
    assert is_nil(session.crf_search_progress)
  end

  test "keeps CRF sample metadata when later progress omits it" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, session} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %CrfSearchProgress{
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
             WorkerSessions.set_crf_search_progress("worker-server-1", %CrfSearchProgress{
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

  test "touches session when transfer progress is reported" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    initial_session = WorkerSessions.get("worker-server-1")
    initial_last_seen = initial_session.last_seen_at

    Process.sleep(1_100)

    assert {:ok, session} =
             WorkerSessions.set_transfer_progress("worker-server-1", %{
               job_id: "job-1",
               video_id: 123,
               transfer_id: "job-1",
               filename: "sample.mkv",
               percent: 25.0,
               bytes_sent: 2_621_440,
               total_bytes: 10_485_760,
               bytes_per_second: 1_048_576,
               eta: 15,
               chunk_index: 2,
               total_chunks: 8
             })

    assert DateTime.compare(session.last_seen_at, initial_last_seen) == :gt
  end

  test "touches session when CRF search progress is reported" do
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    initial_session = WorkerSessions.get("worker-server-1")
    initial_last_seen = initial_session.last_seen_at

    Process.sleep(1_100)

    assert {:ok, session} =
             WorkerSessions.set_crf_search_progress("worker-server-1", %CrfSearchProgress{
               video_id: 123,
               percent: 25.0,
               fps: 24.0,
               crf: 28.0,
               sample_num: 3,
               total_samples: 5
             })

    assert DateTime.compare(session.last_seen_at, initial_last_seen) == :gt
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
             WorkerSessions.set_crf_search_progress("worker-server-1", %CrfSearchProgress{
               video_id: video.id,
               percent: 25.0,
               fps: 24.0,
               crf: 28.0,
               sample_num: 2,
               total_samples: 5
             })

    assert session.active_video_id == video.id
    assert session.phase == :crf_searching

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
    assert session.phase == :crf_searching
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
             WorkerSessions.set_crf_search_progress("worker-server-1", %CrfSearchProgress{
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
    assert session.phase == :idle
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

  test "retains independent encode job state when a worker reconnects" do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoding})
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, _session} =
             WorkerSessions.assign_job("worker-server-1", %Job{
               job_id: "encode-#{video.id}",
               job_type: :encode,
               video_id: video.id,
               phase: :receiving_input
             })

    progress = %EncodeProgress{
      job_id: "encode-#{video.id}",
      video_id: video.id,
      percent: 42.0,
      fps: 12.5,
      output_bytes: 1_000,
      output_percent: 10.0
    }

    assert {:ok, _session} =
             WorkerSessions.set_encode_progress("worker-server-1", progress)

    assert {:ok, reconnected} =
             WorkerSessions.register(worker_session_attrs(server_worker_id: "worker-server-2"))

    assert is_nil(WorkerSessions.get("worker-server-1"))

    assert %Job{
             job_type: :encode,
             video_id: video_id,
             phase: :encoding,
             progress: %EncodeProgress{percent: 42.0}
           } = reconnected.jobs["encode-#{video.id}"]

    assert video_id == video.id
    assert {:ok, cleared} = WorkerSessions.clear_job("worker-server-2", "encode-#{video.id}")
    assert cleared.jobs == %{}
  end

  test "restores an encode job from progress after the server restarts" do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoding})
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    progress = %EncodeProgress{
      job_id: "encode-#{video.id}",
      video_id: video.id,
      percent: 42.0,
      fps: 12.5,
      output_bytes: 1_000,
      output_percent: 10.0
    }

    assert {:ok, session} = WorkerSessions.set_encode_progress("worker-server-1", progress)

    assert %Job{job_type: :encode, video_id: video_id, phase: :encoding} =
             session.jobs[progress.job_id]

    assert video_id == video.id
  end

  test "requeues an encode when its retained worker session expires" do
    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
    vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
    video = Fixtures.choose_vmaf(video, vmaf)
    {:ok, video} = Media.mark_as_encoding(video)
    assert {:ok, _session} = WorkerSessions.register(worker_session_attrs())

    assert {:ok, _session} =
             WorkerSessions.assign_job("worker-server-1", %Job{
               job_id: "encode-#{video.id}",
               job_type: :encode,
               video_id: video.id
             })

    assert {:ok, [_session]} = WorkerSessions.expire_stale(0)
    assert Media.get_video(video.id).state == :crf_searched
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
