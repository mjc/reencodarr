defmodule Reencodarr.AbAv1.ProcessControlTest do
  use Reencodarr.UnitCase, async: false

  alias Reencodarr.AbAv1.ProcessControl

  setup do
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
end
