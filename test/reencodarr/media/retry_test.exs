defmodule Reencodarr.Media.RetryTest do
  use Reencodarr.DataCase
  alias Reencodarr.Media
  alias Reencodarr.Media.{Retry, VideoActions, VideoFailure}

  test "encoding retry retains chosen CRF and resolves failures atomically" do
    {video, vmaf} = Fixtures.video_with_vmaf_fixture(%{state: :failed})

    {:ok, video} =
      Media.update_video(video, %{chosen_vmaf_id: vmaf.id, worker_attempt_id: "old-attempt"})

    {:ok, failure} =
      Media.record_video_failure(video, :encoding, :timeout, message: "upload interrupted")

    assert {:ok, retried} = Retry.video(video.id)
    assert retried.state == :crf_searched
    assert retried.chosen_vmaf_id == vmaf.id
    assert retried.bitrate == video.bitrate
    assert retried.worker_attempt_id == nil
    assert Repo.get!(VideoFailure, failure.id).resolved
    assert Media.get_vmafs_for_video(video.id) != []
  end

  test "CRF retry keeps analyzed metadata; incomplete metadata returns to analysis" do
    for {bitrate, target} <- [{3_500_000, :analyzed}, {nil, :needs_analysis}] do
      {:ok, video} = Fixtures.failed_video_fixture(%{bitrate: bitrate})

      {:ok, _} =
        Media.record_video_failure(video, :crf_search, :timeout, message: "search interrupted")

      assert {:ok, retried} = Retry.video(video.id)
      assert retried.state == target
    end
  end

  test "analysis retry is explicit and a stale retry cannot reset an encoded video" do
    {video, vmaf} = Fixtures.video_with_vmaf_fixture(%{state: :failed})
    {:ok, video} = Media.update_video(video, %{chosen_vmaf_id: vmaf.id})
    {:ok, _} = Media.record_video_failure(video, :encoding, :timeout, message: "interrupted")
    assert {:ok, %{state: :needs_analysis, bitrate: nil}} = Retry.video(video.id, :analyze)

    {:ok, encoded} = Fixtures.encoded_video_fixture()
    assert {:error, :not_failed} = Retry.video(encoded.id)
    assert Media.get_video!(encoded.id).state == :encoded
  end

  test "operator metadata actions protect jobs even when a page has stale state" do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoding})

    for action <- [:reset, :reanalyze, :delete],
        do: assert({:error, :active} = VideoActions.mutate(video.id, action))

    assert Media.reset_videos_to_needs_analysis([video.id]) == 0
    assert Media.get_video!(video.id).state == :encoding
  end

  test "reanalyze actually returns a queued video to the analysis queue" do
    {video, vmaf} = Fixtures.video_with_vmaf_fixture(%{state: :analyzed})
    {:ok, video} = Media.update_video(video, %{chosen_vmaf_id: vmaf.id})
    assert {:ok, _} = VideoActions.mutate(video.id, :reanalyze)
    refreshed = Media.get_video!(video.id)
    assert refreshed.state == :needs_analysis
    assert refreshed.chosen_vmaf_id == nil
    assert refreshed.bitrate == nil
    assert Media.get_vmafs_for_video(video.id) == []
  end

  test "worker controls target the owning remote job and reject absent workers" do
    alias Reencodarr.AbAv1.WorkerSessions
    :meck.new(WorkerSessions, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(WorkerSessions) end)

    :meck.expect(WorkerSessions, :list, fn ->
      [
        %{
          server_worker_id: "session-1",
          jobs: %{"attempt-1" => %{job_id: "attempt-1", video_id: 42, active: true}}
        }
      ]
    end)

    :meck.expect(WorkerSessions, :request_control, fn "session-1", "attempt-1", :stop -> :ok end)
    assert :ok = VideoActions.control(42, :stop)
    assert {:error, :worker_unavailable} = VideoActions.control(43, :stop)
    assert :meck.called(WorkerSessions, :request_control, ["session-1", "attempt-1", :stop])
  end

  test "stale bad-file actions cannot queue or dismiss an active replacement" do
    {:ok, video} = Fixtures.video_fixture()

    {:ok, issue} =
      Media.create_bad_file_issue(video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "bad"
      })

    {:ok, _} = Media.update_bad_file_issue_status(issue, :waiting_for_replacement)
    assert {:error, :not_reviewable} = Media.enqueue_bad_file_issue(issue)
    assert {:error, :not_reviewable} = Media.dismiss_bad_file_issue(issue)
    assert Media.get_bad_file_issue!(issue.id).status == :waiting_for_replacement
  end
end
