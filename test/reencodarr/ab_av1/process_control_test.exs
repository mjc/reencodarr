defmodule Reencodarr.AbAv1.ProcessControlTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.{ProcessControl, WorkerSessions}
  alias Reencodarr.AbAv1.WorkerSessions.Job

  setup do
    WorkerSessions.reset()

    start_supervised!(
      {ProcessControl,
       auto_resume_hour: DateTime.utc_now().hour,
       auto_resume_timezone: "Etc/UTC",
       auto_resume_after_ms: 4 * 60 * 60 * 1000,
       check_interval_ms: :timer.hours(1)}
    )

    :ok
  end

  test "services are not suspended by default" do
    refute ProcessControl.suspended?(:crf_searcher)
    refute ProcessControl.suspended?(:encoder)
  end

  test "worker toggle gates both queues even when workers are idle" do
    assert {:ok, :paused, 0} = ProcessControl.toggle_workers()
    assert ProcessControl.suspended?(:crf_searcher)
    assert ProcessControl.suspended?(:encoder)

    assert {:ok, :running, 0} = ProcessControl.toggle_workers()
    refute ProcessControl.suspended?(:crf_searcher)
    refute ProcessControl.suspended?(:encoder)
  end

  test "worker toggle uses durable controls for both job types on all connected workers" do
    for {job_type, worker_id} <- [{:crf_search, "tina"}, {:encode, "tali"}] do
      job_id = "#{job_type}-toggle"
      owner_field = if job_type == :encode, do: :encode_worker_id, else: :crf_search_worker_id
      state = if job_type == :encode, do: :encoding, else: :crf_searching

      {:ok, video} =
        Fixtures.video_fixture(%{
          owner_field => worker_id,
          :state => state,
          :worker_attempt_id => job_id
        })

      {:ok, _session} =
        WorkerSessions.register(%{
          server_worker_id: worker_id,
          client_worker_id: worker_id,
          protocol_version: 1,
          version: "0.11.5",
          capabilities: %{"encode" => true, "crf_search" => true}
        })

      {:ok, _session} =
        WorkerSessions.assign_job(worker_id, %Job{
          job_id: job_id,
          job_type: job_type,
          video_id: video.id
        })

      Phoenix.PubSub.subscribe(Reencodarr.PubSub, WorkerSessions.control_topic(worker_id))
    end

    for {action, desired} <- [{:pause, :paused}, {:resume, :running}] do
      assert {:ok, ^desired, 2} = ProcessControl.toggle_workers()

      for session <- WorkerSessions.list(), {job_id, job} <- session.jobs do
        assert_receive {:worker_control, ^action, ^job_id, command_id}
        assert is_binary(command_id)
        assert job.desired_control_state == desired
        assert Reencodarr.Media.get_video(job.video_id).worker_control_desired_state == desired
      end
    end

    assert {:ok, :paused, 2} = ProcessControl.toggle_workers()
    assert :ok = WorkerSessions.request_control("tina", "crf_search-toggle", :resume)

    assert ProcessControl.suspended?(:crf_searcher)
    assert ProcessControl.suspended?(:encoder)
    assert {:ok, :paused, 2} = ProcessControl.toggle_workers()

    for session <- WorkerSessions.list(), {_job_id, job} <- session.jobs do
      assert job.desired_control_state == :paused
    end

    ProcessControl.resume(:crf_searcher)
    ProcessControl.resume(:encoder)
    assert {:ok, :running, 2} = ProcessControl.toggle_workers()
  end

  test "worker toggle normalizes a mixed queue pause to paused" do
    ProcessControl.suspend(:encoder)
    assert {:ok, :paused, 0} = ProcessControl.toggle_workers()
    assert ProcessControl.suspended?(:crf_searcher)
    assert ProcessControl.suspended?(:encoder)
  end

  test "worker toggle reports control failures instead of claiming every job was paused" do
    {:ok, _session} =
      WorkerSessions.register(%{
        server_worker_id: "stale-server",
        client_worker_id: "stale-client",
        protocol_version: 1,
        version: "0.11.5",
        capabilities: %{"encode" => true}
      })

    {:ok, _session} =
      WorkerSessions.assign_job("stale-server", %Job{
        job_id: "stale-job",
        job_type: :encode,
        video_id: 999_999_999
      })

    assert {:error, :paused, [{"stale-server", "stale-job"}]} = ProcessControl.toggle_workers()
    assert ProcessControl.suspended?(:crf_searcher)
    assert ProcessControl.suspended?(:encoder)
  end

  test "tracks CRF searcher suspension independently from encoder" do
    assert :ok = ProcessControl.suspend(:crf_searcher)

    assert ProcessControl.suspended?(:crf_searcher)
    refute ProcessControl.suspended?(:encoder)

    assert :ok = ProcessControl.resume(:crf_searcher)
    refute ProcessControl.suspended?(:crf_searcher)
  end

  test "tracks encoder suspension independently from CRF searcher" do
    assert :ok = ProcessControl.suspend(:encoder)

    assert ProcessControl.suspended?(:encoder)
    refute ProcessControl.suspended?(:crf_searcher)

    assert :ok = ProcessControl.resume(:encoder)
    refute ProcessControl.suspended?(:encoder)
  end

  test "auto-resumes services paused for more than four hours during the configured hour" do
    five_hours_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)

    ProcessControl.force_suspend_at(:encoder, five_hours_ago)
    ProcessControl.force_suspend_at(:crf_searcher, five_hours_ago)
    Process.sleep(20)

    assert ProcessControl.suspended?(:encoder)
    assert ProcessControl.suspended?(:crf_searcher)

    ProcessControl.auto_resume_check()
    Process.sleep(20)

    refute ProcessControl.suspended?(:encoder)
    refute ProcessControl.suspended?(:crf_searcher)
  end

  test "auto-resume keeps recently paused services paused" do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -60 * 60, :second)

    ProcessControl.force_suspend_at(:encoder, one_hour_ago)
    Process.sleep(20)

    ProcessControl.auto_resume_check()
    Process.sleep(20)

    assert ProcessControl.suspended?(:encoder)
  end

  test "auto-resumes worker jobs paused for more than four hours" do
    job_id = "encode-auto-resume"
    five_hours_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)

    {:ok, video} =
      Fixtures.video_fixture(%{
        state: :encoding,
        encode_worker_id: "worker-client",
        worker_attempt_id: job_id,
        worker_control_desired_state: :paused,
        worker_control_acknowledged_state: :paused,
        worker_control_requested_at: five_hours_ago
      })

    assert {:ok, _session} =
             WorkerSessions.register(%{
               server_worker_id: "worker-server",
               client_worker_id: "worker-client",
               protocol_version: 1,
               version: "0.11.4",
               capabilities: %{"encode" => true}
             })

    assert {:ok, _session} =
             WorkerSessions.assign_job("worker-server", %Job{
               job_id: job_id,
               job_type: :encode,
               video_id: video.id,
               control_state: :paused,
               desired_control_state: :paused
             })

    Phoenix.PubSub.subscribe(
      Reencodarr.PubSub,
      ReencodarrWeb.WorkerChannel.worker_control_topic("worker-server")
    )

    ProcessControl.auto_resume_check()

    assert_receive {:worker_control, :resume, ^job_id, command_id}
    assert is_binary(command_id)
    assert Reencodarr.Media.get_video(video.id).worker_control_desired_state == :running

    assert WorkerSessions.get("worker-server").jobs[job_id].desired_control_state == :running
  end

  test "worker activity after pausing does not postpone auto-resume" do
    five_hours_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)

    {:ok, video} =
      Fixtures.video_fixture(%{
        state: :encoding,
        encode_worker_id: "offline-worker",
        worker_attempt_id: "paused-before-progress",
        worker_control_desired_state: :paused,
        worker_control_acknowledged_state: :paused,
        worker_control_requested_at: five_hours_ago
      })

    from(v in Reencodarr.Media.Video, where: v.id == ^video.id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])

    ProcessControl.auto_resume_check()
    Process.sleep(20)

    assert Reencodarr.Media.get_video(video.id).worker_control_desired_state == :running
  end

  test "auto-resume persists for disconnected workers but leaves recent pauses alone" do
    five_hours_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)

    {:ok, old_pause} =
      Fixtures.video_fixture(%{
        state: :crf_searching,
        crf_search_worker_id: "offline-worker",
        worker_attempt_id: "old-pause",
        worker_control_desired_state: :paused,
        worker_control_acknowledged_state: :paused,
        worker_control_requested_at: five_hours_ago
      })

    {:ok, recent_pause} =
      Fixtures.video_fixture(%{
        state: :encoding,
        encode_worker_id: "offline-worker",
        worker_attempt_id: "recent-pause",
        worker_control_desired_state: :paused,
        worker_control_acknowledged_state: :paused,
        worker_control_requested_at: DateTime.utc_now()
      })

    ProcessControl.auto_resume_check()
    Process.sleep(20)

    assert Reencodarr.Media.get_video(old_pause.id).worker_control_desired_state == :running
    assert Reencodarr.Media.get_video(recent_pause.id).worker_control_desired_state == :paused
  end
end
