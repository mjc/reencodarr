defmodule Reencodarr.Media.WorkerControlTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  describe "request_worker_control/3" do
    test "persists a command only for the exact active attempt" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-a",
          worker_attempt_id: "encode-current",
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      assert {:ok, command} =
               Media.request_worker_control(video.id, "encode-current", :pause)

      assert command.action == :pause
      assert command.job_id == "encode-current"
      assert is_binary(command.command_id)

      updated = Media.get_video(video.id)
      assert updated.worker_control_desired_state == :paused
      assert updated.worker_control_acknowledged_state == :running
      assert updated.worker_control_command_id == command.command_id

      assert {:error, :stale_worker_attempt} =
               Media.request_worker_control(video.id, "encode-old", :stop)

      assert Media.get_video(video.id).worker_control_command_id == command.command_id
    end
  end

  describe "acknowledge_worker_control/5" do
    test "accepts only the current command and records acknowledged reality" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          crf_search_worker_id: "worker-a",
          worker_attempt_id: "crf-current",
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      assert {:ok, command} =
               Media.request_worker_control(video.id, "crf-current", :pause)

      assert {:error, :stale_worker_control} =
               Media.acknowledge_worker_control(
                 video.id,
                 "crf-current",
                 "wrong-command",
                 :paused,
                 :crf_search
               )

      assert {:ok, :applied} =
               Media.acknowledge_worker_control(
                 video.id,
                 "crf-current",
                 command.command_id,
                 :paused,
                 :crf_search
               )

      assert Media.get_video(video.id).worker_control_acknowledged_state == :paused
    end

    test "fails a stopped attempt and inserts its operator failure exactly once" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-a",
          worker_attempt_id: "encode-current",
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      assert {:ok, command} =
               Media.request_worker_control(video.id, "encode-current", :stop)

      assert {:ok, :applied} =
               Media.acknowledge_worker_control(
                 video.id,
                 "encode-current",
                 command.command_id,
                 :stopped,
                 :encode
               )

      assert {:ok, :duplicate} =
               Media.acknowledge_worker_control(
                 video.id,
                 "encode-current",
                 command.command_id,
                 :stopped,
                 :encode
               )

      assert %{
               state: :failed,
               worker_attempt_id: "encode-current",
               worker_control_acknowledged_state: :stopped
             } = Media.get_video(video.id)

      assert [%{failure_code: "OPERATOR_FAILED"}] = Media.get_video_failures(video.id)
    end

    test "records watchdog recovery as a stalled worker failure" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-a",
          worker_attempt_id: "encode-stalled",
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      assert {:ok, command} =
               Media.request_worker_control(video.id, "encode-stalled", :stop, :stalled)

      assert {:ok, :applied} =
               Media.acknowledge_worker_control(
                 video.id,
                 "encode-stalled",
                 command.command_id,
                 :stopped,
                 :encode
               )

      assert [%{failure_code: "WORKER_STALLED", system_context: context}] =
               Media.get_video_failures(video.id)

      assert context["worker_watchdog"]
    end
  end
end
