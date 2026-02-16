defmodule Reencodarr.AbAv1.CrfSearchTest do
  @moduledoc """
  Unit tests for CRF search business logic functions.
  These tests focus on pure function behavior without GenServer interactions.
  """

  use ExUnit.Case, async: true
  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.AbAv1.Helper

  describe "build_crf_search_args/2" do
    test "builds basic CRF search args without preset 6" do
      video = %{path: "/test/video.mkv"}
      target_vmaf = 95

      args = CrfSearch.build_crf_search_args(video, target_vmaf)

      assert "crf-search" in args
      assert "--input" in args
      assert "/test/video.mkv" in args
      assert "--min-vmaf" in args
      assert "95" in args
      # Should NOT include preset 6 by default
      refute "--preset" in args || "6" in args
    end

    test "does not include preset 6 by default" do
      video = %{path: "/test/video.mkv"}
      target_vmaf = 90

      args = CrfSearch.build_crf_search_args(video, target_vmaf)

      # Should NOT include preset 6 by default
      refute "--preset" in args || "6" in args
    end

    test "always includes basic required arguments" do
      video = %{path: "/test/video.mkv"}
      target_vmaf = 90

      args = CrfSearch.build_crf_search_args(video, target_vmaf)

      assert "crf-search" in args
      assert "--input" in args
      assert "/test/video.mkv" in args
      assert "--min-vmaf" in args
      assert "90" in args
    end
  end

  describe "handle_cast/2 - port opening error handling" do
    setup do
      # Clean up any existing mocks
      try do
        :meck.unload()
      rescue
        _ -> :ok
      end

      # Start the CrfSearch GenServer for testing
      {:ok, pid} = CrfSearch.start_link([])

      on_exit(fn ->
        try do
          :meck.unload()
        rescue
          _ -> :ok
        end
      end)

      %{pid: pid}
    end

    test "handles {:error, :not_found} from open_port - marks video as failed and stays available",
         %{pid: _pid} do
      # Mock Helper.open_port to return {:error, :not_found}
      :meck.new(Helper, [:passthrough])
      :meck.expect(Helper, :open_port, fn _args -> {:error, :not_found} end)

      # Mock Media functions to prevent actual DB calls
      :meck.new(Reencodarr.Media, [:passthrough])
      :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn _video -> {:ok, %{}} end)

      :meck.expect(Reencodarr.Media, :record_video_failure, fn _video, _stage, _category, _opts ->
        {:ok, %{}}
      end)

      video = %{id: 123, path: "/test/video.mkv"}
      vmaf_percent = 95

      # Send the cast
      GenServer.cast(CrfSearch, {:crf_search, video, vmaf_percent})

      # Give it time to process
      Process.sleep(100)

      # Verify GenServer is still available (port should be :none)
      state = :sys.get_state(CrfSearch)
      assert state.port == :none
      assert CrfSearch.available?() == true

      # Verify video was marked as failed
      assert :meck.called(Reencodarr.Media, :record_video_failure, :_)
    end

    test "handles {:ok, port} from open_port - proceeds normally", %{pid: _pid} do
      # Mock Helper.open_port to return {:ok, port}
      fake_port = Port.open({:spawn, "cat"}, [:binary])
      :meck.new(Helper, [:passthrough])
      :meck.expect(Helper, :open_port, fn _args -> {:ok, fake_port} end)

      # Mock Media functions
      :meck.new(Reencodarr.Media, [:passthrough])
      :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn _video -> {:ok, %{}} end)

      # Create a complete video object with all required fields
      video = %{
        id: 456,
        path: "/test/video.mkv",
        size: 1_000_000_000,
        width: 1920,
        height: 1080,
        hdr: false,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        bitrate: 5_000_000
      }

      vmaf_percent = 95

      # Send the cast
      GenServer.cast(CrfSearch, {:crf_search, video, vmaf_percent})

      # Give it time to process
      Process.sleep(100)

      # Verify GenServer is busy (port should be the fake_port)
      state = :sys.get_state(CrfSearch)
      assert state.port == fake_port
      assert CrfSearch.available?() == false

      # Clean up
      Port.close(fake_port)
    end

    test "marks video as crf_searching ONLY AFTER successful port open", %{pid: _pid} do
      # This test verifies the ordering fix
      # Track the order of calls
      test_pid = self()

      :meck.new(Helper, [:passthrough])

      :meck.expect(Helper, :open_port, fn _args ->
        send(test_pid, :open_port_called)
        {:error, :not_found}
      end)

      :meck.new(Reencodarr.Media, [:passthrough])

      :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn _video ->
        send(test_pid, :mark_as_crf_searching_called)
        {:ok, %{}}
      end)

      :meck.expect(Reencodarr.Media, :record_video_failure, fn _video, _stage, _category, _opts ->
        {:ok, %{}}
      end)

      video = %{id: 789, path: "/test/video.mkv"}
      vmaf_percent = 95

      GenServer.cast(CrfSearch, {:crf_search, video, vmaf_percent})
      Process.sleep(100)

      # Verify mark_as_crf_searching was NOT called when port open failed
      refute_received :mark_as_crf_searching_called
      assert_received :open_port_called
    end
  end
end
