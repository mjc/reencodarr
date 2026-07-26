defmodule Reencodarr.Media.WorkerTerminalTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  test "only one delivery claims the exact active attempt" do
    {:ok, video} =
      Fixtures.video_fixture(%{
        state: :encoding,
        encode_worker_id: "worker-a",
        worker_attempt_id: "encode-current"
      })

    assert {:ok, :claimed} =
             Media.claim_worker_terminal(video.id, "encode-current", :encode)

    assert {:error, :terminal_busy} =
             Media.claim_worker_terminal(video.id, "encode-current", :encode)

    assert {:error, :stale_worker_attempt} =
             Media.claim_worker_terminal(video.id, "encode-old", :encode)

    assert %DateTime{} = Media.get_video(video.id).worker_terminal_claimed_at
  end

  test "a failed terminal handler releases only its exact attempt" do
    {:ok, video} =
      Fixtures.video_fixture(%{
        state: :crf_searching,
        crf_search_worker_id: "worker-a",
        worker_attempt_id: "crf-current"
      })

    assert {:ok, :claimed} =
             Media.claim_worker_terminal(video.id, "crf-current", :crf_search)

    assert :ok = Media.release_worker_terminal(video.id, "crf-old", :crf_search)
    assert %DateTime{} = Media.get_video(video.id).worker_terminal_claimed_at

    assert :ok = Media.release_worker_terminal(video.id, "crf-current", :crf_search)
    assert is_nil(Media.get_video(video.id).worker_terminal_claimed_at)
  end

  test "boot recovery releases only claims left by an older app instance" do
    booted_at = DateTime.utc_now()

    {:ok, stale} =
      Fixtures.video_fixture(%{
        state: :encoding,
        worker_attempt_id: "stale",
        worker_terminal_claimed_at: DateTime.add(booted_at, -1, :second)
      })

    {:ok, current} =
      Fixtures.video_fixture(%{
        state: :encoding,
        worker_attempt_id: "current",
        worker_terminal_claimed_at: DateTime.add(booted_at, 1, :second)
      })

    assert :ok = Media.release_worker_terminal_claims_before(booted_at)
    assert is_nil(Media.get_video(stale.id).worker_terminal_claimed_at)
    assert %DateTime{} = Media.get_video(current.id).worker_terminal_claimed_at
  end
end
