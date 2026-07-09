defmodule Reencodarr.AbAv1.WorkerJobStateMachineTest do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.WorkerJobStateMachine

  test "complete transfer progress moves the worker to input ready" do
    session = session()

    assert {:ok, session} = WorkerJobStateMachine.assign_video(session, 123, :receiving_input)
    assert session.phase == :receiving_input
    assert session.active_video_id == 123

    assert {:ok, session} =
             WorkerJobStateMachine.set_transfer_progress(session, %{
               video_id: 123,
               percent: 100.0
             })

    assert session.phase == :input_ready
    assert session.transfer_progress.percent == 100.0

    assert {:ok, session} = WorkerJobStateMachine.finish_transfer(session)
    assert session.phase == :input_ready
    assert session.active_video_id == 123
    assert session.transfer_progress.percent == 100.0
  end

  test "CRF progress wins over stale transfer progress" do
    session =
      session()
      |> Map.merge(%{
        phase: :receiving_input,
        active_video_id: 123,
        transfer_progress: %{video_id: 123, percent: 100.0}
      })

    assert {:ok, session} =
             WorkerJobStateMachine.set_crf_search_progress(session, %{
               video_id: 123,
               percent: 75.0
             })

    assert session.phase == :crf_searching
    assert session.active_video_id == 123
    assert is_nil(session.transfer_progress)
    assert session.crf_search_progress.percent == 75.0
  end

  test "progress cannot move an active worker to a different video" do
    session =
      session()
      |> Map.merge(%{
        phase: :receiving_input,
        active_video_id: 123,
        transfer_progress: %{video_id: 123, percent: 50.0}
      })

    assert {:error, :invalid_worker_phase} =
             WorkerJobStateMachine.set_transfer_progress(session, %{
               video_id: 456,
               percent: 75.0
             })

    assert {:error, :invalid_worker_phase} =
             WorkerJobStateMachine.set_crf_search_progress(session, %{
               video_id: 456,
               percent: 10.0
             })
  end

  test "transfer progress for the active video moves CRF search back to receiving input" do
    session =
      session()
      |> Map.merge(%{
        phase: :crf_searching,
        active_video_id: 123,
        crf_search_progress: %{video_id: 123, percent: 25.0}
      })

    assert {:ok, session} =
             WorkerJobStateMachine.set_transfer_progress(session, %{
               video_id: 123,
               percent: 25.0
             })

    assert session.phase == :receiving_input
    assert session.active_video_id == 123
    assert session.transfer_progress.percent == 25.0
    assert is_nil(session.crf_search_progress)
  end

  test "clearing active work is the only transition that makes the worker idle" do
    session =
      session()
      |> Map.merge(%{
        phase: :crf_searching,
        active_video_id: 123,
        crf_search_progress: %{video_id: 123, percent: 75.0}
      })

    assert {:ok, session} = WorkerJobStateMachine.clear_video(session)
    assert session.phase == :idle
    assert is_nil(session.active_video_id)
    assert is_nil(session.crf_search_progress)
  end

  defp session do
    %{
      server_worker_id: "worker-server-1",
      client_worker_id: "worker-client-1",
      version: "0.11.4",
      protocol_version: 1,
      capabilities: %{"crf_search" => true},
      phase: :idle,
      active_video_id: nil,
      transfer_progress: nil,
      crf_search_progress: nil,
      resource_usage: nil,
      connected_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    }
  end
end
