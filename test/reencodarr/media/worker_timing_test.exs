defmodule Reencodarr.Media.WorkerTimingTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.WorkerProtocol.JobTiming
  alias Reencodarr.{Fixtures, Media, Repo}
  alias Reencodarr.Media.{Video, WorkerTiming}

  defp job(video, type, id, milliseconds) do
    %JobTiming{video_id: video.id, job_type: type, job_id: id, active_milliseconds: milliseconds}
  end

  test "unknown historical timings stay nil; cumulative reports only add their delta" do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoding})
    assert is_nil(video.encode_seconds)

    Repo.update_all(from(v in Video, where: v.id == ^video.id),
      set: [worker_attempt_id: "encode-one", encode_worker_id: "tina"]
    )

    assert {:ok, :applied} = WorkerTiming.record("tina", job(video, :encode, "encode-one", 1500))

    assert {:ok, :duplicate} =
             WorkerTiming.record("tina", job(video, :encode, "encode-one", 1500))

    assert {:ok, :duplicate} =
             WorkerTiming.record("tina", job(video, :encode, "encode-one", 1000))

    assert {:ok, :applied} = WorkerTiming.record("tina", job(video, :encode, "encode-one", 3000))
    assert Media.get_video(video.id).encode_seconds == 3.0
    assert WorkerTiming.active_milliseconds(video.id, "encode-one") == 3000
    assert WorkerTiming.active_milliseconds(video.id, "new-attempt") == 0
    assert is_nil(Media.get_video(video.id).crf_search_seconds)

    assert Repo.get!(WorkerTiming, "encode-one").worker_id == "tina"
  end

  test "paused reports freeze, reconnect resumes, and finalization is counted once" do
    {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

    Repo.update_all(from(v in Video, where: v.id == ^video.id),
      set: [worker_attempt_id: "crf-one", crf_search_worker_id: "tali"]
    )

    assert {:ok, :applied} = WorkerTiming.record("tali", job(video, :crf_search, "crf-one", 2000))
    # A paused worker sends the same monotonic counter regardless of wall-clock time.
    assert {:ok, :duplicate} =
             WorkerTiming.record("tali", job(video, :crf_search, "crf-one", 2000))

    assert {:ok, :applied} = WorkerTiming.record("tali", job(video, :crf_search, "crf-one", 4000))
    assert {:ok, :applied} = WorkerTiming.finish(video.id, "crf-one", 250)
    assert {:ok, :duplicate} = WorkerTiming.finish(video.id, "crf-one", 900)
    assert Media.get_video(video.id).crf_search_seconds == 4.25
  end

  test "failed attempts accumulate across retries but stale and foreign reports are fenced" do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoding})

    Repo.update_all(from(v in Video, where: v.id == ^video.id),
      set: [worker_attempt_id: "first", encode_worker_id: "tina"]
    )

    assert {:ok, :applied} = WorkerTiming.record("tina", job(video, :encode, "first", 5000))
    assert {:ok, :applied} = WorkerTiming.finish(video.id, "first", 0)

    Repo.update_all(from(v in Video, where: v.id == ^video.id),
      set: [worker_attempt_id: "retry", encode_worker_id: "tali"]
    )

    assert {:error, :stale_worker_attempt} =
             WorkerTiming.record("tina", job(video, :encode, "first", 9000))

    assert {:error, :stale_worker_attempt} =
             WorkerTiming.record("tina", job(video, :encode, "retry", 5000))

    assert {:ok, :applied} = WorkerTiming.record("tali", job(video, :encode, "retry", 7000))
    assert Media.get_video(video.id).encode_seconds == 12.0
  end

  test "timing replay after completion survives loss of in-memory sessions" do
    {:ok, video} = Fixtures.video_fixture(%{state: :encoding})

    Repo.update_all(from(v in Video, where: v.id == ^video.id),
      set: [worker_attempt_id: "done", encode_worker_id: "tina"]
    )

    report = job(video, :encode, "done", 2000)
    assert {:ok, :applied} = WorkerTiming.record("tina", report)

    Repo.update_all(from(v in Video, where: v.id == ^video.id),
      set: [state: :encoded, worker_attempt_id: nil, encode_worker_id: nil]
    )

    assert {:ok, :applied} = WorkerTiming.finish(video.id, "done", 300)
    assert {:ok, :duplicate} = WorkerTiming.record("tina", report)
    assert Media.get_video(video.id).encode_seconds == 2.3

    assert {:error, :stale_worker_attempt} =
             WorkerTiming.record("tina", %{report | active_milliseconds: 8000})

    assert Media.get_video(video.id).encode_seconds == 2.3
  end

  test "failed server finalization work accumulates until a successful finalization" do
    {:ok, video} =
      Fixtures.video_fixture(%{
        state: :encoding,
        worker_attempt_id: "delivery-retry",
        encode_worker_id: "tina"
      })

    assert {:ok, :applied} =
             WorkerTiming.record("tina", job(video, :encode, "delivery-retry", 3000))

    assert {:ok, :applied} = WorkerTiming.finish(video.id, "delivery-retry", 1000, false)
    assert {:ok, :applied} = WorkerTiming.finish(video.id, "delivery-retry", 2000, true)
    assert {:ok, :duplicate} = WorkerTiming.finish(video.id, "delivery-retry", 8000, true)
    assert Media.get_video(video.id).encode_seconds == 6.0
    checkpoint = Repo.get!(WorkerTiming, "delivery-retry")
    assert checkpoint.finalized
    assert checkpoint.finalization_milliseconds == 3000
  end
end
