defmodule Reencodarr.Integration.Preset6WorkflowTest do
  @moduledoc """
  Integration test to verify the complete workflow:
  1. CRF search fails
  2. Video is retried with --preset 6
  3. Encoder uses --preset 6 when encoding
  """
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.{CrfSearch, Encode}
  alias Reencodarr.{Media, Repo}

  import ExUnit.CaptureLog

  describe "preset 6 retry workflow integration" do
    setup do
      {:ok, video} = Fixtures.video_fixture(%{path: "/test/integration.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "complete workflow: CRF search failure -> preset 6 retry -> encoding with preset 6", %{
      video: video
    } do
      # Step 1: Create initial VMAF records (without preset 6)
      {:ok, _vmaf1} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          params: ["--preset", "medium"]
        })

      # Step 2: Test that should_retry_with_preset_6 returns {:retry, vmafs}
      retry_result = CrfSearch.should_retry_with_preset_6_for_test(video.id)
      assert match?({:retry, _vmafs}, retry_result)

      # Step 3: Simulate the retry by creating new VMAF with --preset 6
      {:ok, preset6_vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 26.0,
          score: 93.5,
          chosen: true,
          params: ["--preset", "6", "--threads", "8"]
        })

      # Step 4: Verify the VMAF has preset 6 params
      assert CrfSearch.has_preset_6_params?(preset6_vmaf.params) == true

      # Step 5: Test that encoder will use the preset 6 parameter
      preset6_vmaf_with_video = Repo.preload(preset6_vmaf, :video)
      encode_args = Encode.build_encode_args_for_test(preset6_vmaf_with_video)

      # Should contain --preset 6
      assert "--preset" in encode_args
      preset_index = Enum.find_index(encode_args, &(&1 == "--preset"))
      assert Enum.at(encode_args, preset_index + 1) == "6"

      # Should also contain other params from VMAF
      assert "--threads" in encode_args
      threads_index = Enum.find_index(encode_args, &(&1 == "--threads"))
      assert Enum.at(encode_args, threads_index + 1) == "8"

      # Step 6: Verify that after retry, should_retry_with_preset_6 returns :already_retried
      retry_result_after = CrfSearch.should_retry_with_preset_6_for_test(video.id)
      assert retry_result_after == :already_retried
    end

    test "handles error line processing and triggers preset 6 retry workflow", %{video: video} do
      # Create initial VMAF record WITHOUT preset 6 (this should trigger retry)
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 30.0,
          score: 88.5,
          params: ["--preset", "medium", "--cpu-used", "4"]
        })

      # First verify that retry should be triggered
      retry_check = CrfSearch.should_retry_with_preset_6_for_test(video.id)

      assert match?({:retry, _vmafs}, retry_check),
             "VMAF state should indicate retry is needed: #{inspect(retry_check)}"

      # Process an error line that should trigger retry logic
      error_line = "Error: Failed to find a suitable crf"

      log =
        capture_log(fn ->
          # Also capture any info level logs
          Logger.configure(level: :info)
          CrfSearch.process_line(error_line, video, [], 95)
        end)

      # Should process error and indicate retry logic
      assert log =~ "Failed to find a suitable CRF"

      # Should indicate retry decision
      assert log =~ "CrfSearch: Retry result:"
    end

    test "build_crf_search_args_with_preset_6 creates correct arguments", %{video: video} do
      # Test the argument building for preset 6 retry
      args = CrfSearch.build_crf_search_args_with_preset_6_for_test(video, 95)

      # Should include basic CRF search args
      assert "crf-search" in args
      assert "--input" in args
      assert video.path in args
      assert "--min-vmaf" in args
      assert "95" in args

      # Should include --preset 6
      assert "--preset" in args
      preset_index = Enum.find_index(args, &(&1 == "--preset"))
      assert Enum.at(args, preset_index + 1) == "6"

      # Should include temp directory
      assert "--temp-dir" in args
    end
  end
end
