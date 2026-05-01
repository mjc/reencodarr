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

    test "running?/0 returns true when GenServer is alive" do
      assert Encode.running?() == true
    end

    test "available?/0 returns :busy when a video is being encoded", %{pid: pid} do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)

      :sys.replace_state(pid, fn state ->
        %{state | video: video, os_pid: nil}
      end)

      assert Encode.available?() == :busy
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
      assert Map.has_key?(state, :partial_line_buffer_bytes)

      assert state.port_status == :available
      assert state.has_video == false
      assert state.video_id == nil
      assert state.os_pid == nil
      assert state.output_lines_count == 0
      assert state.partial_line_buffer_bytes == 0
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

  describe "extract_and_store_progress/2" do
    # We test via send_progress_line/2 which calls extract_and_store_progress internally.
    # Instead we unit-test the private function indirectly by injecting a line via handle_info.

    test "parses integer fps without crashing (no bare rescue)", %{pid: pid} do
      # Previously String.to_float("42") would raise; bare rescue hid the bug
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)
      vmaf = %{vmaf | video: video}

      fake_encoder = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(pid, fn state ->
        ref = Process.monitor(fake_encoder)

        %{
          state
          | video: video,
            vmaf: vmaf,
            encoder_monitor: ref,
            output_lines: [],
            output_file: "/tmp/test.mkv",
            encode_args: [],
            partial_line_buffer: ""
        }
      end)

      # Send a line with integer fps (no decimal point)
      line_with_int_fps = "42%, 5 fps, eta 1h 23m"

      send(pid, {Reencodarr.AbAv1.Encoder, {:line, line_with_int_fps}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.last_progress != nil
      assert state.last_progress.percent == 42.0
      assert state.last_progress.fps == 5.0
    end
  end

  describe "encode cast when busy" do
    test "ignores new encode request and leaves state unchanged when already encoding", %{
      pid: pid
    } do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)

      :sys.replace_state(pid, fn state ->
        %{state | video: video, os_pid: nil}
      end)

      state_before = :sys.get_state(pid)
      other_vmaf = %Reencodarr.Media.Vmaf{id: 999, video_id: video.id, crf: 28.0}
      GenServer.cast(Encode, {:encode, other_vmaf})
      Process.sleep(50)

      state_after = :sys.get_state(pid)
      assert state_after.video.id == state_before.video.id
    end
  end

  describe "encoder start failures" do
    test "records failure and does not leave video stuck in encoding", %{pid: _pid} do
      :meck.new(Reencodarr.AbAv1.Encoder, [:passthrough])

      on_exit(fn ->
        try do
          :meck.unload(Reencodarr.AbAv1.Encoder)
        rescue
          ErlangError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      :meck.expect(Reencodarr.AbAv1.Encoder, :start, fn _args, _metadata ->
        {:error, :enoent}
      end)

      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      vmaf = %{vmaf | video: video}

      GenServer.cast(Encode, {:encode, vmaf})

      wait_until(fn ->
        Media.get_video!(video.id).state == :failed
      end)

      state = :sys.get_state(Encode)
      assert state.video == :none
      assert Encode.available?() == :available

      failures = Media.get_video_failures(video.id)
      assert [%{failure_stage: :encoding, failure_code: "EXIT_port_error"} | _] = failures
    end
  end

  describe "partial chunk buffering" do
    test "caps retained output lines", %{pid: pid} do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)
      vmaf = %{vmaf | video: video}

      :sys.replace_state(pid, fn state ->
        %{state | video: video, vmaf: vmaf, output_lines: [], partial_line_buffer: ""}
      end)

      Enum.each(1..1100, fn index ->
        send(pid, {Reencodarr.AbAv1.Encoder, {:line, "unmatched encode output #{index}"}})
      end)

      wait_until(fn ->
        :sys.get_state(pid).output_lines |> length() == 1024
      end)

      state = :sys.get_state(pid)
      assert length(state.output_lines) == 1024
      assert hd(state.output_lines) == "unmatched encode output 1100"
      assert "unmatched encode output 1" in state.output_lines
      assert "unmatched encode output 75" not in state.output_lines
    end

    test "accumulates partial line chunks into buffer", %{pid: pid} do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)
      vmaf = %{vmaf | video: video}

      :sys.replace_state(pid, fn state ->
        %{state | video: video, vmaf: vmaf, partial_line_buffer: "start_"}
      end)

      send(pid, {Reencodarr.AbAv1.Encoder, {:partial, "more_data"}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.partial_line_buffer == "start_more_data"
    end

    test "caps retained partial line bytes", %{pid: pid} do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, video} = Media.mark_as_encoding(video)
      vmaf = %{vmaf | video: video}

      :sys.replace_state(pid, fn state ->
        %{state | video: video, vmaf: vmaf, partial_line_buffer: ""}
      end)

      send(pid, {Reencodarr.AbAv1.Encoder, {:partial, String.duplicate("a", 20_000)}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert byte_size(state.partial_line_buffer) == 16_384
      assert Encode.get_state().partial_line_buffer_bytes == 16_384
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met before timeout")
end
