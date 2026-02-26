defmodule Reencodarr.AbAv1.PortCleanupTest do
  @moduledoc """
  Tests that OS processes spawned by port holders are killed on shutdown.

  Port.close/1 only closes Erlang-side file descriptors — it does NOT send
  any signal to the OS process. Since ab-av1 reads from video files (not
  stdin), it never notices the closed pipe and keeps running as an orphan.

  The fix: Helper.kill_os_process/1 sends SIGTERM, and the CrfSearcher/Encoder
  terminate(:shutdown) and kill() callbacks use it.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag capture_log: true

  alias Reencodarr.AbAv1.{CrfSearcher, Encoder, Helper}

  setup do
    case :meck.unload() do
      :ok -> :ok
      _ -> :ok
    end

    :ok
  end

  describe "Helper.kill_os_process/1" do
    test "returns :ok for nil os_pid" do
      assert :ok = Helper.kill_os_process(nil)
    end

    test "sends SIGTERM to the given os_pid" do
      :meck.new(System, [:passthrough])
      :meck.expect(System, :cmd, fn "kill", args, _opts -> {args, 0} end)

      assert :ok = Helper.kill_os_process(12_345)

      assert :meck.called(System, :cmd, ["kill", ["-TERM", "12345"], :_])

      :meck.unload(System)
    end

    test "returns :ok even when kill command fails (process already dead)" do
      :meck.new(System, [:passthrough])
      :meck.expect(System, :cmd, fn "kill", _args, _opts -> {"No such process", 1} end)

      assert :ok = Helper.kill_os_process(99_999)

      :meck.unload(System)
    end
  end

  describe "CrfSearcher terminate(:shutdown) kills OS process" do
    test "sends SIGTERM to os_pid" do
      :meck.new(System, [:passthrough])
      :meck.expect(System, :cmd, fn "kill", _args, _opts -> {"", 0} end)

      port = Port.open({:spawn, "cat"}, [:binary, :exit_status])

      state = %{
        port: port,
        os_pid: 99_999,
        metadata: %{},
        output_lines: [],
        subscriber: nil
      }

      capture_log(fn ->
        CrfSearcher.terminate(:shutdown, state)
      end)

      assert :meck.called(System, :cmd, ["kill", ["-TERM", "99999"], :_])

      :meck.unload(System)
    end
  end

  describe "CrfSearcher kill() kills OS process" do
    test "kill handler sends SIGTERM to os_pid before stopping" do
      :meck.new(System, [:passthrough])
      :meck.expect(System, :cmd, fn "kill", _args, _opts -> {"", 0} end)

      port = Port.open({:spawn, "cat"}, [:binary, :exit_status])

      state = %{
        port: port,
        os_pid: 42_000,
        metadata: %{},
        output_lines: [],
        subscriber: nil
      }

      {:stop, :normal, :ok, new_state} =
        CrfSearcher.handle_call(:kill, {self(), make_ref()}, state)

      assert new_state.os_pid == nil
      assert new_state.port == :none
      assert :meck.called(System, :cmd, ["kill", ["-TERM", "42000"], :_])

      :meck.unload(System)
    end
  end

  describe "Encoder terminate(:shutdown) kills OS process" do
    test "sends SIGTERM to os_pid" do
      :meck.new(System, [:passthrough])
      :meck.expect(System, :cmd, fn "kill", _args, _opts -> {"", 0} end)

      port = Port.open({:spawn, "cat"}, [:binary, :exit_status])

      state = %{
        port: port,
        os_pid: 99_999,
        metadata: %{},
        output_lines: [],
        subscriber: nil
      }

      capture_log(fn ->
        Encoder.terminate(:shutdown, state)
      end)

      assert :meck.called(System, :cmd, ["kill", ["-TERM", "99999"], :_])

      :meck.unload(System)
    end
  end

  describe "Encoder kill() kills OS process" do
    test "kill handler sends SIGTERM to os_pid before stopping" do
      :meck.new(System, [:passthrough])
      :meck.expect(System, :cmd, fn "kill", _args, _opts -> {"", 0} end)

      port = Port.open({:spawn, "cat"}, [:binary, :exit_status])

      state = %{
        port: port,
        os_pid: 42_000,
        metadata: %{},
        output_lines: [],
        subscriber: nil
      }

      {:stop, :normal, :ok, new_state} =
        Encoder.handle_call(:kill, {self(), make_ref()}, state)

      assert new_state.os_pid == nil
      assert new_state.port == :none
      assert :meck.called(System, :cmd, ["kill", ["-TERM", "42000"], :_])

      :meck.unload(System)
    end
  end
end
