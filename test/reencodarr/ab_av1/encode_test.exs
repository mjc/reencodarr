defmodule Reencodarr.AbAv1.EncodeTest do
  use Reencodarr.DataCase, async: false
  @moduletag capture_log: true

  alias Reencodarr.AbAv1.Encode

  describe "encode availability" do
    setup do
      {:ok, pid} = Encode.start_link([])
      %{pid: pid}
    end

    test "GenServer starts with video :none and is available", %{pid: _pid} do
      state = :sys.get_state(Encode)
      assert state.video == :none
      assert Encode.available?() == :available
    end

    test "GenServer starts with trap_exit enabled", %{pid: pid} do
      process_info = Process.info(pid, :trap_exit)
      assert process_info == {:trap_exit, true}
    end

    test "GenServer starts with os_pid nil", %{pid: _pid} do
      state = :sys.get_state(Encode)
      assert state.os_pid == nil
    end
  end

  describe "reset_if_stuck/0" do
    setup do
      {:ok, pid} = Encode.start_link([])
      %{pid: pid}
    end

    test "resets state to available when called", %{pid: _pid} do
      # Call reset_if_stuck
      assert Encode.reset_if_stuck() == :ok

      # Verify encoder is available
      assert Encode.available?() == :available

      # Verify state is clean
      state = :sys.get_state(Encode)
      assert state.video == :none
      assert state.encoder_monitor == nil
      assert state.os_pid == nil
    end
  end

  describe "get_state/0" do
    setup do
      {:ok, pid} = Encode.start_link([])
      %{pid: pid}
    end

    test "returns debug info about current state", %{pid: _pid} do
      state = Encode.get_state()

      assert is_map(state)
      assert Map.has_key?(state, :port_status)
      assert Map.has_key?(state, :has_video)
      assert Map.has_key?(state, :video_id)
      assert Map.has_key?(state, :os_pid)
      assert Map.has_key?(state, :output_lines_count)

      # Initial state should be available
      assert state.port_status == :available
      assert state.has_video == false
      assert state.video_id == nil
      assert state.os_pid == nil
      assert state.output_lines_count == 0
    end
  end

  # Note: Full port opening error handling tests require Vmaf structs from the database.
  # These are covered by integration tests.
  # The key fix is already implemented: Helper.open_port returns {:ok, port} | {:error, :not_found}
  # and the Encode module's start_encode_port/2 handles both cases gracefully.
end
