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

    {:ok, video} =
      Fixtures.video_fixture(%{
        state: :encoding,
        encode_worker_id: "worker-client",
        worker_attempt_id: job_id,
        worker_control_desired_state: :paused,
        worker_control_acknowledged_state: :paused
      })

    five_hours_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)

    from(v in Reencodarr.Media.Video, where: v.id == ^video.id)
    |> Repo.update_all(set: [updated_at: five_hours_ago])

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

  test "auto-resume persists for disconnected workers but leaves recent pauses alone" do
    {:ok, old_pause} =
      Fixtures.video_fixture(%{
        state: :crf_searching,
        crf_search_worker_id: "offline-worker",
        worker_attempt_id: "old-pause",
        worker_control_desired_state: :paused,
        worker_control_acknowledged_state: :paused
      })

    {:ok, recent_pause} =
      Fixtures.video_fixture(%{
        state: :encoding,
        encode_worker_id: "offline-worker",
        worker_attempt_id: "recent-pause",
        worker_control_desired_state: :paused,
        worker_control_acknowledged_state: :paused
      })

    from(v in Reencodarr.Media.Video, where: v.id == ^old_pause.id)
    |> Repo.update_all(set: [updated_at: DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)])

    ProcessControl.auto_resume_check()
    Process.sleep(20)

    assert Reencodarr.Media.get_video(old_pause.id).worker_control_desired_state == :running
    assert Reencodarr.Media.get_video(recent_pause.id).worker_control_desired_state == :paused
  end
end
