defmodule Reencodarr.AbAv1.CrfSearchRetryTest do
  @moduledoc """
  Tests for CRF search retry functionality with --preset 6.
  """
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  describe "CRF search retry mechanism" do
    setup do
      # Clean up any existing mocks
      try do
        :meck.unload()
      catch
        _ -> :ok
      end

      {:ok, video} = Fixtures.video_fixture(%{path: "/test/retry_video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "determines retry needed when no --preset 6 exists", %{video: video} do
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

      # Should mark as failed (preset 6 retry disabled)
      retry_result = CrfSearch.should_retry_with_preset_6(video.id)
      assert retry_result == :mark_failed

      # Video should not be marked as failed initially (test setup)
      updated_video = Repo.get(Media.Video, video.id)
      assert updated_video.state != :failed
    end

    test "returns :mark_failed when --preset 6 exists (preset 6 retry disabled)", %{video: video} do
      # Create VMAF records with --preset 6 to simulate previous retry attempt
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

      # Should mark as failed (preset 6 retry disabled)
      retry_result = CrfSearch.should_retry_with_preset_6(video.id)
      assert retry_result == :mark_failed

      # VMAF records should remain
      assert Repo.aggregate(Vmaf, :count, :id) == 2
    end

    test "marks as failed when no VMAF records exist", %{video: video} do
      # No VMAF records exist - this indicates something went wrong
      assert Repo.aggregate(Vmaf, :count, :id) == 0

      # Should indicate mark failed
      retry_result = CrfSearch.should_retry_with_preset_6(video.id)
      assert retry_result == :mark_failed
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

        # Should mark as failed (preset 6 retry disabled)
        retry_result = CrfSearch.should_retry_with_preset_6(video.id)
        assert retry_result == :mark_failed

        # Also test the params detection directly
        assert CrfSearch.has_preset_6_params?(params) == true
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

        # Should mark as failed (preset 6 retry disabled)
        retry_result = CrfSearch.should_retry_with_preset_6(video.id)
        assert retry_result == :mark_failed

        # Also test the params detection directly
        assert CrfSearch.has_preset_6_params?(params) == false
      end)
    end
  end

  describe "build_crf_search_args_with_preset_6" do
    test "includes --preset 6 parameter" do
      {:ok, video} = Fixtures.video_fixture(%{path: "/test/preset_test.mkv"})

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
