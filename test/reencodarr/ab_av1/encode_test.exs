defmodule Reencodarr.AbAv1.EncodeTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.AbAv1.Helper

  describe "handle_cast/2 - port opening error handling" do
    setup do
      # Start the Encode GenServer for testing
      {:ok, pid} = Encode.start_link([])
      %{pid: pid}
    end

    test "handles {:error, :not_found} from open_port - marks video as failed and stays available",
         %{pid: _pid} do
      # This test will fail until we implement the fix
      # Mock Helper.open_port to return {:error, :not_found}
      :meck.new(Helper, [:passthrough])
      :meck.expect(Helper, :open_port, fn _args -> {:error, :not_found} end)

      # Mock Media functions to prevent actual DB calls
      :meck.new(Reencodarr.Media, [:passthrough])
      :meck.expect(Reencodarr.Media, :mark_as_encoding, fn _video -> {:ok, %{}} end)

      :meck.expect(Reencodarr.Media, :mark_video_failure, fn _video_id,
                                                             _stage,
                                                             _category,
                                                             _code,
                                                             _message,
                                                             _context ->
        {:ok, %{}}
      end)

      # Create a mock vmaf with video
      video = %{id: 123, path: "/test/video.mkv", size: 1_000_000_000}
      vmaf = %{video: video, crf: 30, score: 95.0, percent: 50}

      # Send the cast
      GenServer.cast(Encode, {:encode, vmaf})

      # Give it time to process
      Process.sleep(100)

      # Verify GenServer is still available (port should be :none)
      state = :sys.get_state(Encode)
      assert state.port == :none
      assert Encode.available?() == true

      # Verify video was marked as failed
      assert :meck.called(Reencodarr.Media, :mark_video_failure, :_)

      :meck.unload(Reencodarr.Media)
      :meck.unload(Helper)
    end

    test "handles {:ok, port} from open_port - proceeds normally", %{pid: _pid} do
      # This test will fail until we implement the fix
      # Mock Helper.open_port to return {:ok, port}
      fake_port = Port.open({:spawn, "cat"}, [:binary])
      :meck.new(Helper, [:passthrough])
      :meck.expect(Helper, :open_port, fn _args -> {:ok, fake_port} end)

      # Mock Media functions
      :meck.new(Reencodarr.Media, [:passthrough])
      :meck.expect(Reencodarr.Media, :mark_as_encoding, fn _video -> {:ok, %{}} end)

      video = %{
        id: 456,
        path: "/test/video.mkv",
        size: 1_000_000_000,
        width: 1920,
        height: 1080,
        hdr: false,
        video_codecs: ["h264"],
        audio_codecs: ["aac"]
      }

      vmaf = %{video: video, crf: 30, score: 95.0, percent: 50, savings: 50.0}

      # Send the cast
      GenServer.cast(Encode, {:encode, vmaf})

      # Give it time to process
      Process.sleep(100)

      # Verify GenServer is busy (port should be the fake_port)
      state = :sys.get_state(Encode)
      assert state.port == fake_port
      assert Encode.available?() == false

      # Clean up
      Port.close(fake_port)
      :meck.unload(Reencodarr.Media)
      :meck.unload(Helper)
    end

    test "does not crash on Port.info when port is :error", %{pid: _pid} do
      # This test verifies that we handle the error case before calling Port.info
      # Currently, the code crashes because Port.info(:error, :os_pid) raises ArgumentError
      :meck.new(Helper, [:passthrough])
      :meck.expect(Helper, :open_port, fn _args -> {:error, :not_found} end)

      :meck.new(Reencodarr.Media, [:passthrough])
      :meck.expect(Reencodarr.Media, :mark_as_encoding, fn _video -> {:ok, %{}} end)

      :meck.expect(Reencodarr.Media, :mark_video_failure, fn _video_id,
                                                             _stage,
                                                             _category,
                                                             _code,
                                                             _message,
                                                             _context ->
        {:ok, %{}}
      end)

      video = %{id: 789, path: "/test/video.mkv", size: 1_000_000_000}
      vmaf = %{video: video, crf: 30, score: 95.0, percent: 50}

      # This should not crash
      GenServer.cast(Encode, {:encode, vmaf})
      Process.sleep(100)

      # If we get here, we didn't crash
      state = :sys.get_state(Encode)
      assert state.port == :none

      :meck.unload(Reencodarr.Media)
      :meck.unload(Helper)
    end
  end
end
