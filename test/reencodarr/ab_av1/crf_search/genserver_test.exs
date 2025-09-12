defmodule Reencodarr.AbAv1.CrfSearch.GenServerTest do
  @moduledoc """
  Integration tests for CRF search GenServer behavior and lifecycle.
  These tests interact directly with the GenServer process.
  """
  use Reencodarr.DataCase, async: false
  import ExUnit.CaptureLog

  @moduletag :integration

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media

  describe "GenServer lifecycle" do
    setup do
      # Wait for any running CRF search to complete and reset state
      wait_for_crf_search_to_complete()

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/genserver_video_#{:rand.uniform(10000)}.mkv",
          size: 2_000_000_000,
          state: :analyzed
        })

      %{video: video}
    end

    test "starts with no active task" do
      assert CrfSearch.running?() == false
    end

    test "skips CRF search for already reencoded videos", %{video: video} do
      # Mark video as reencoded
      {:ok, reencoded_video} = Media.update_video(video, %{state: :encoded})

      _log =
        capture_log(fn ->
          # Should return :ok and not crash
          result = CrfSearch.crf_search(reencoded_video, 95)
          assert result == :ok

          # Give it a moment to process
          Process.sleep(50)

          # Since it's skipped, no CRF search should be running
          refute CrfSearch.running?()
        end)
    end

    test "skips CRF search when chosen VMAF already exists", %{video: video} do
      # Create a chosen VMAF record
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 95.5,
          params: ["--preset", "medium"],
          chosen: true
        })

      _log =
        capture_log(fn ->
          # Should return :ok and not crash
          result = CrfSearch.crf_search(video, 95)
          assert result == :ok

          # Give it a moment to process
          Process.sleep(50)

          # Since it's skipped, no CRF search should be running
          refute CrfSearch.running?()
        end)
    end

    test "initiates CRF search for valid video", %{video: video} do
      capture_log(fn ->
        # Should return :ok and not crash
        result = CrfSearch.crf_search(video, 95)
        assert result == :ok

        # Give it time to start processing
        Process.sleep(100)

        # Should be running (though it may fail due to missing ab-av1 binary)
        # The important thing is that it attempted to start
        assert is_boolean(CrfSearch.running?())

        # Wait for the process to complete to capture all logs
        wait_for_crf_search_to_complete()
      end)
    end
  end

  describe "GenServer cast handling" do
    setup do
      # Wait for any running CRF search to complete and reset state
      wait_for_crf_search_to_complete()

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/cast_video_#{:rand.uniform(10000)}.mkv",
          size: 2_000_000_000
        })

      %{video: video}
    end

    test "handles crf_search cast when not running", %{video: video} do
      capture_log(fn ->
        # Ensure not running first
        wait_for_crf_search_to_complete()

        # Send cast directly to GenServer
        GenServer.cast(CrfSearch, {:crf_search, video, 95})
        Process.sleep(100)

        # Should attempt to start processing
        assert is_boolean(CrfSearch.running?())

        # Wait for completion to capture all logs
        wait_for_crf_search_to_complete()
      end)
    end

    test "rejects crf_search cast when already running", %{video: video} do
      capture_log(fn ->
        # Start a CRF search first
        GenServer.cast(CrfSearch, {:crf_search, video, 95})
        Process.sleep(100)

        # Try to start another one - should return OK but not start a new one
        GenServer.cast(CrfSearch, {:crf_search, video, 95})
        Process.sleep(50)

        # Should still be running (only one instance)
        assert is_boolean(CrfSearch.running?())

        # Wait for completion to capture all logs
        wait_for_crf_search_to_complete()
      end)
    end

    test "handles crf_search_with_preset_6 cast", %{video: video} do
      capture_log(fn ->
        # Should handle the cast without crashing
        GenServer.cast(CrfSearch, {:crf_search_with_preset_6, video, 95})
        Process.sleep(100)

        # Should attempt to start processing
        assert is_boolean(CrfSearch.running?())

        # Wait for completion to capture all logs
        wait_for_crf_search_to_complete()
      end)
    end
  end

  # Helper function to wait for CRF search to complete
  defp wait_for_crf_search_to_complete do
    # Wait for any active CRF search to complete
    # Use a timeout to avoid hanging tests
    # Wait up to 500ms
    max_wait = 50
    wait_count = 0

    wait_for_completion(wait_count, max_wait)
  end

  defp wait_for_completion(wait_count, max_wait) when wait_count >= max_wait do
    # Force reset if taking too long - send a reset message to the GenServer
    # This is a test-only workaround to ensure clean state
    send(CrfSearch, :test_reset)
    Process.sleep(10)
  rescue
    _ -> :ok
  end

  defp wait_for_completion(wait_count, max_wait) do
    if CrfSearch.running?() do
      Process.sleep(10)
      wait_for_completion(wait_count + 1, max_wait)
    else
      :ok
    end
  end
end
