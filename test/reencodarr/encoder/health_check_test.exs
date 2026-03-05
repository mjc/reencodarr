defmodule Reencodarr.Encoder.HealthCheckTest do
  use Reencodarr.DataCase, async: false
  import ExUnit.CaptureLog

  alias Reencodarr.Encoder.HealthCheck

  # Start an isolated HealthCheck GenServer per test (not the app-wide one)
  defp start_health_check do
    {:ok, pid} = GenServer.start_link(HealthCheck, [])
    pid
  end

  describe "init/1" do
    test "starts with encoding: false and no video tracked" do
      pid = start_health_check()
      state = :sys.get_state(pid)

      assert state.encoding == false
      assert is_nil(state.video_id)
      assert is_nil(state.video_path)
      assert is_nil(state.last_progress_time)
      assert state.warned == false
      assert is_nil(state.os_pid)
    end
  end

  describe "handle_info(:encoding_started)" do
    test "records encoding state from event data" do
      pid = start_health_check()

      send(pid, {:encoding_started, %{video_id: 42, filename: "/media/video.mkv", os_pid: 1234}})
      # Allow time for the message to be processed
      :timer.sleep(50)

      state = :sys.get_state(pid)

      assert state.encoding == true
      assert state.video_id == 42
      assert state.video_path == "/media/video.mkv"
      assert state.os_pid == 1234
      assert is_integer(state.last_progress_time)
      assert state.warned == false
    end
  end

  describe "handle_info(:encoding_progress)" do
    test "updates last_progress_time and resets warned" do
      pid = start_health_check()

      send(pid, {:encoding_started, %{video_id: 1, filename: "/v.mkv", os_pid: nil}})
      :timer.sleep(20)

      before_state = :sys.get_state(pid)

      :timer.sleep(10)
      send(pid, {:encoding_progress, %{percent: 55}})
      :timer.sleep(20)

      after_state = :sys.get_state(pid)

      assert after_state.last_progress_time >= before_state.last_progress_time
      assert after_state.warned == false
    end
  end

  describe "handle_info(:encoding_completed)" do
    test "clears all encoding state" do
      pid = start_health_check()

      send(pid, {:encoding_started, %{video_id: 10, filename: "/v.mkv", os_pid: 5555}})
      :timer.sleep(20)

      send(pid, {:encoding_completed, %{}})
      :timer.sleep(20)

      state = :sys.get_state(pid)

      assert state.encoding == false
      assert is_nil(state.video_id)
      assert is_nil(state.video_path)
      assert is_nil(state.last_progress_time)
      assert state.warned == false
      assert is_nil(state.os_pid)
    end
  end

  describe "handle_info(:health_check)" do
    test "no encoding in progress: state unchanged" do
      pid = start_health_check()

      capture_log(fn ->
        send(pid, :health_check)
        :timer.sleep(50)
      end)

      state = :sys.get_state(pid)
      assert state.encoding == false
    end

    test "encoding with very recent progress: no kill, no warn" do
      pid = start_health_check()

      send(pid, {:encoding_started, %{video_id: 1, filename: "/v.mkv", os_pid: nil}})
      :timer.sleep(20)

      log =
        capture_log(fn ->
          send(pid, :health_check)
          :timer.sleep(50)
        end)

      state = :sys.get_state(pid)
      # Still encoding (not killed)
      assert state.encoding == true
      refute log =~ "stuck"
      refute log =~ "Killing"
    end

    test "encoding with nil progress time: initializes it and stays encoding" do
      pid = start_health_check()

      # Override state to simulate encoding with nil progress time
      :sys.replace_state(pid, fn state ->
        %{state | encoding: true, video_id: 99, last_progress_time: nil, os_pid: nil}
      end)

      capture_log(fn ->
        send(pid, :health_check)
        :timer.sleep(50)
      end)

      state = :sys.get_state(pid)
      assert state.encoding == true
      assert is_integer(state.last_progress_time)
    end
  end

  describe "ignores unrelated PubSub events" do
    test "unknown message does not crash the GenServer" do
      pid = start_health_check()

      capture_log(fn ->
        send(pid, {:some_unknown_event, %{data: "value"}})
        :timer.sleep(20)
      end)

      assert Process.alive?(pid)
    end
  end
end
