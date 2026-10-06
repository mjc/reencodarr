defmodule ReencodarrWeb.WorkerActivityTest do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.WorkerSessions.Job
  alias ReencodarrWeb.WorkerActivity

  test "humanizes watchdog state" do
    now = ~U[2026-08-06 12:00:00Z]

    job = %Job{
      job_id: "encode-1",
      job_type: :encode,
      video_id: 1,
      phase: :output_upload,
      last_activity_at: DateTime.add(now, -24, :hour),
      recovery_action: :stop_requested
    }

    assert WorkerActivity.label(job, now) ==
             "Output upload · last activity 24h ago · Stopping stalled job"
  end
end
