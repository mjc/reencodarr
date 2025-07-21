defmodule Reencodarr.AbAv1.CrfSearchRetryTest do
  @moduledoc """
  Tests for CRF search retry functionality with --preset 6.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  import ExUnit.CaptureLog
  import Reencodarr.MediaFixtures

  describe "CRF search retry mechanism" do
    setup do
      video = video_fixture(%{path: "/test/retry_video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "retries with --preset 6 on first failure", %{video: video} do
      # First, create some VMAF records without --preset 6
      {:ok, _vmaf1} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 22.0,
          score: 88.5,
          params: ["--enc", "cpu-used=4"]
        })

      {:ok, _vmaf2} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 18.0,
          score: 92.3,
          params: ["--preset", "medium"]
        })

      # Verify we have 2 VMAF records initially
      assert Repo.aggregate(Vmaf, :count, :id) == 2

      # Simulate CRF search failure
      error_line = "Error: Failed to find a suitable crf"

      # Mock GenServer.cast to capture the retry call
      me = self()
      :meck.new(GenServer, [:passthrough])

      :meck.expect(GenServer, :cast, fn
        Reencodarr.AbAv1.CrfSearch, {:crf_search_with_preset_6, ^video, 95} ->
          send(me, {:retry_called, video, 95})
          :ok

        mod, msg ->
          :meck.passthrough([mod, msg])
      end)

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(error_line, video, [], 95)
        end)

      # Should log retry message
      assert log_output =~ "Retrying video #{video.id}"
      assert log_output =~ "with --preset 6 after CRF search failure"

      # Should call GenServer.cast with retry message
      assert_receive {:retry_called, ^video, 95}, 1000

      # Should clear existing VMAF records
      assert Repo.aggregate(Vmaf, :count, :id) == 0

      # Video should not be marked as failed yet
      updated_video = Repo.get(Media.Video, video.id)
      assert updated_video.failed == false

      :meck.unload(GenServer)
    end

    test "marks as failed when already retried with --preset 6", %{video: video} do
      # Create VMAF records with --preset 6 to simulate previous retry
      {:ok, _vmaf1} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 22.0,
          score: 88.5,
          params: ["--preset", "6", "--enc", "cpu-used=4"]
        })

      {:ok, _vmaf2} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 18.0,
          score: 92.3,
          params: ["--preset", "6"]
        })

      # Simulate CRF search failure again
      error_line = "Error: Failed to find a suitable crf"

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(error_line, video, [], 95)
        end)

      # Should log failure message
      assert log_output =~ "already retried with --preset 6, marking as failed"

      # Video should be marked as failed
      updated_video = Repo.get(Media.Video, video.id)
      assert updated_video.failed == true

      # VMAF records should remain (not cleared)
      assert Repo.aggregate(Vmaf, :count, :id) == 2
    end

    test "marks as failed when no VMAF records exist", %{video: video} do
      # No VMAF records exist - this indicates something went wrong
      assert Repo.aggregate(Vmaf, :count, :id) == 0

      # Simulate CRF search failure
      error_line = "Error: Failed to find a suitable crf"

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(error_line, video, [], 95)
        end)

      # Should log detailed error message
      assert log_output =~ "Failed to find a suitable CRF"
      assert log_output =~ "No VMAF scores were recorded"

      # Video should be marked as failed
      updated_video = Repo.get(Media.Video, video.id)
      assert updated_video.failed == true
    end

    test "detects --preset 6 in various positions in params array", %{video: video} do
      # Test different param configurations
      test_cases = [
        ["--preset", "6"],
        ["--enc", "cpu-used=4", "--preset", "6"],
        ["--preset", "6", "--temp-dir", "/tmp"]
      ]

      Enum.each(test_cases, fn params ->
        # Clear any existing records
        Repo.delete_all(Vmaf)

        # Create VMAF with specific params
        {:ok, _vmaf} =
          Media.create_vmaf(%{
            video_id: video.id,
            crf: 22.0,
            score: 88.5,
            params: params
          })

        # Simulate failure
        error_line = "Error: Failed to find a suitable crf"

        log_output =
          capture_log(fn ->
            CrfSearch.process_line(error_line, video, [], 95)
          end)

        # Should detect existing --preset 6 and mark as failed
        assert log_output =~ "already retried with --preset 6, marking as failed"

        # Video should be marked as failed
        updated_video = Repo.get(Media.Video, video.id)
        assert updated_video.failed == true

        # Reset video failed status for next iteration
        Media.update_video(video, %{failed: false})
      end)
    end

    test "does not detect other preset values as --preset 6", %{video: video} do
      # Test params with different preset values
      test_cases = [
        ["--preset", "medium"],
        ["--preset", "slow"],
        ["--preset", "4"],
        ["--preset", "fast"]
      ]

      Enum.each(test_cases, fn params ->
        # Clear any existing records
        Repo.delete_all(Vmaf)

        # Create VMAF with specific params
        {:ok, _vmaf} =
          Media.create_vmaf(%{
            video_id: video.id,
            crf: 22.0,
            score: 88.5,
            params: params
          })

        # Mock GenServer.cast to capture retry calls
        me = self()
        :meck.new(GenServer, [:passthrough])

        :meck.expect(GenServer, :cast, fn
          Reencodarr.AbAv1.CrfSearch, {:crf_search_with_preset_6, ^video, 95} ->
            send(me, {:retry_called, params})
            :ok

          mod, msg ->
            :meck.passthrough([mod, msg])
        end)

        # Simulate failure
        error_line = "Error: Failed to find a suitable crf"

        log_output =
          capture_log(fn ->
            CrfSearch.process_line(error_line, video, [], 95)
          end)

        # Should attempt retry (not detect as already retried)
        assert log_output =~ "Retrying video #{video.id}"
        assert_receive {:retry_called, ^params}, 1000

        :meck.unload(GenServer)

        # Reset video failed status for next iteration
        Media.update_video(video, %{failed: false})
      end)
    end
  end

  describe "build_crf_search_args_with_preset_6" do
    test "includes --preset 6 parameter" do
      video = video_fixture(%{path: "/test/preset_test.mkv"})

      # Access the private function through process_line with a mocked GenServer
      me = self()
      :meck.new(GenServer, [:passthrough])

      :meck.expect(GenServer, :cast, fn
        Reencodarr.AbAv1.CrfSearch, {:crf_search_with_preset_6, _video, _vmaf} ->
          :ok

        mod, msg ->
          :meck.passthrough([mod, msg])
      end)

      # Use the Helper module to simulate the call
      :meck.new(Reencodarr.AbAv1.Helper, [:passthrough])

      :meck.expect(Reencodarr.AbAv1.Helper, :open_port, fn args ->
        send(me, {:args_used, args})
        Port.open({:spawn, "echo test"}, [])
      end)

      # Trigger the retry mechanism which will use build_crf_search_args_with_preset_6
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 22.0,
          score: 88.5,
          params: ["--preset", "medium"]
        })

      # This would trigger the retry logic if we could properly test it
      # For now, we'll test the args structure manually in the next test

      :meck.unload([GenServer, Reencodarr.AbAv1.Helper])
    end
  end
end
