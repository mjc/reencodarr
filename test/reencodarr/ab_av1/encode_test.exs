defmodule Reencodarr.AbAv1.EncodeTest do
  use Reencodarr.DataCase, async: false
  @moduletag capture_log: true

  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.Media

  # Shared setup: ensure only one Encode GenServer exists at a time
  setup do
    case GenServer.whereis(Encode) do
      nil -> :ok
      existing -> stop_encode(existing)
    end

    {:ok, pid} = Encode.start_link([])
    on_exit(fn -> stop_encode(pid) end)
    %{pid: pid}
  end

  defp stop_encode(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "encode availability" do
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
    test "resets state to available when called", %{pid: _pid} do
      assert Encode.reset_if_stuck() == :ok
      assert Encode.available?() == :available

      state = :sys.get_state(Encode)
      assert state.video == :none
      assert state.encoder_monitor == nil
      assert state.os_pid == nil
    end
  end

  describe "get_state/0" do
    test "returns debug info about current state", %{pid: _pid} do
      state = Encode.get_state()

      assert is_map(state)
      assert Map.has_key?(state, :port_status)
      assert Map.has_key?(state, :has_video)
      assert Map.has_key?(state, :video_id)
      assert Map.has_key?(state, :os_pid)
      assert Map.has_key?(state, :output_lines_count)

      assert state.port_status == :available
      assert state.has_video == false
      assert state.video_id == nil
      assert state.os_pid == nil
      assert state.output_lines_count == 0
    end
  end

  describe "DOWN handler resets video state" do
    test "resets video from encoding back to crf_searched when encoder dies", %{pid: pid} do
      # Create a video in encoding state with a chosen VMAF
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)
      assert video.state == :encoding

      vmaf = %{vmaf | video: video}

      # Spawn a fake "encoder" process
      fake_encoder = spawn(fn -> Process.sleep(:infinity) end)

      # Inject state — monitor created inside GenServer so the DOWN goes there
      :sys.replace_state(pid, fn state ->
        monitor_ref = Process.monitor(fake_encoder)

        %{
          state
          | video: video,
            vmaf: vmaf,
            encoder_monitor: monitor_ref,
            output_lines: ["some output"],
            output_file: "/tmp/test_output.mkv",
            encode_args: ["--crf", "28"]
        }
      end)

      # Kill the fake encoder — triggers the DOWN handler inside the GenServer
      Process.exit(fake_encoder, :kill)
      Process.sleep(100)

      # Video should be reset to crf_searched (not stuck in encoding)
      updated_video = Reencodarr.Repo.get!(Reencodarr.Media.Video, video.id)
      assert updated_video.state == :crf_searched

      # GenServer should be available again
      assert Encode.available?() == :available

      # A failure should be recorded
      failures = Media.get_video_failures(video.id)
      assert failures != []
      failure = List.first(failures)
      assert failure.failure_stage == :encoding
      assert failure.failure_code == "EXIT_encoder_died"
    end

    test "resets video even when vmaf is :none (edge case)", %{pid: pid} do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)

      fake_encoder = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(pid, fn state ->
        monitor_ref = Process.monitor(fake_encoder)

        %{
          state
          | video: video,
            vmaf: :none,
            encoder_monitor: monitor_ref,
            output_lines: [],
            output_file: :none,
            encode_args: []
        }
      end)

      Process.exit(fake_encoder, :kill)
      Process.sleep(100)

      updated_video = Reencodarr.Repo.get!(Reencodarr.Media.Video, video.id)
      assert updated_video.state == :crf_searched

      assert Encode.available?() == :available
    end
  end
end
