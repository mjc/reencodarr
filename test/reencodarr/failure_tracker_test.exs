defmodule Reencodarr.FailureTrackerTest do
  use Reencodarr.DataCase
  import ExUnit.CaptureLog

  alias Reencodarr.{FailureTracker, Media}

  # Helper to capture logs for FailureTracker operations
  defp with_captured_logs(fun) do
    capture_log(fun)
  end

  describe "analysis failures" do
    test "records file access failure" do
      video = Fixtures.video_fixture()

      _log =
        capture_log(fn ->
          {:ok, failure} = FailureTracker.record_file_access_failure(video, "File not found")

          assert failure.failure_stage == :analysis
          assert failure.failure_category == :file_access
          assert failure.failure_code == "FILE_ACCESS"
          assert failure.failure_message == "File access failed: File not found"
          assert failure.video_id == video.id

          # Video should be marked as failed
          updated_video = Repo.get(Media.Video, video.id)
          assert updated_video.failed == true
        end)
    end

    test "records mediainfo parsing failure" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_mediainfo_failure(video, "Invalid JSON output")

          assert failure.failure_stage == :analysis
          assert failure.failure_category == :mediainfo_parsing
          assert failure.failure_code == "MEDIAINFO_PARSE"
          assert failure.system_context.error == "Invalid JSON output"
        end)
    end
  end

  describe "crf search failures" do
    test "records crf optimization failure with tested scores" do
      video = Fixtures.video_fixture()
      tested_scores = [{20.0, 96.5}, {22.0, 94.2}]

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_crf_optimization_failure(video, 95.0, tested_scores)

          assert failure.failure_stage == :crf_search
          assert failure.failure_category == :crf_optimization
          assert failure.failure_code == "CRF_NOT_FOUND"
          assert failure.system_context.target_vmaf == 95.0
          # Scores are converted to maps for JSON serialization
          assert failure.system_context.tested_scores == [
                   %{crf: 20.0, score: 96.5},
                   %{crf: 22.0, score: 94.2}
                 ]

          assert failure.system_context.score_count == 2
        end)
    end

    test "records size limit failure" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_size_limit_failure(video, "12.5 GB")

          assert failure.failure_stage == :crf_search
          assert failure.failure_category == :size_limits
          assert failure.failure_code == "SIZE_LIMIT"
          assert failure.system_context.estimated_size == "12.5 GB"
          assert failure.system_context.size_limit == "10GB"
        end)
    end

    test "records preset retry failure" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_preset_retry_failure(video, 6, 1)

          assert failure.failure_stage == :crf_search
          assert failure.failure_category == :preset_retry
          assert failure.retry_count == 1
          assert failure.system_context.preset == 6
        end)
    end
  end

  describe "encoding failures" do
    test "records process failure with exit code classification" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_process_failure(video, 137)

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :resource_exhaustion
          assert failure.failure_code == "EXIT_137"
          assert failure.system_context.original_exit_code == 137
          assert failure.system_context.classification == :resource_exhaustion
        end)
    end

    test "classifies different exit codes correctly" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          # Test OOM
          {:ok, failure1} = FailureTracker.record_process_failure(video, 137)
          assert failure1.failure_category == :resource_exhaustion

          # Test standard encoding failure
          {:ok, failure2} = FailureTracker.record_process_failure(video, 1)
          assert failure2.failure_category == :process_failure

          # Test configuration error
          {:ok, failure3} = FailureTracker.record_process_failure(video, 2)
          assert failure3.failure_category == :configuration
        end)
    end

    test "records timeout failure" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_timeout_failure(video, "30 minutes")

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :timeout
          assert failure.system_context.timeout_duration == "30 minutes"
        end)
    end
  end

  describe "post processing failures" do
    test "records file operation failure" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_file_operation_failure(
              video,
              :move,
              "/tmp/source.mkv",
              "/dest/target.mkv",
              "Permission denied"
            )

          assert failure.failure_stage == :post_process
          assert failure.failure_category == :file_operations
          assert failure.failure_code == "FILE_OP_MOVE"
          assert failure.system_context.operation == :move
          assert failure.system_context.source == "/tmp/source.mkv"
          assert failure.system_context.destination == "/dest/target.mkv"
          assert failure.system_context.error == "Permission denied"
        end)
    end
  end

  describe "system context" do
    test "enriches context with system information" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_file_access_failure(video, "Test failure")

          # System context should include enriched information
          assert failure.system_context.elixir_version
          assert failure.system_context.os_type
          assert failure.system_context.timestamp
          assert failure.system_context.node
          assert failure.system_context.reason == "Test failure"
        end)
    end
  end

  describe "failure resolution" do
    test "resolves failures for a video" do
      video = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          # Create multiple failures
          {:ok, failure1} = FailureTracker.record_file_access_failure(video, "Error 1")
          {:ok, failure2} = FailureTracker.record_mediainfo_failure(video, "Error 2")

          assert failure1.resolved == false
          assert failure2.resolved == false

          # Resolve all failures for the video
          Media.resolve_video_failures(video.id)

          # Check that failures are resolved
          updated_failure1 = Repo.get(Media.VideoFailure, failure1.id)
          updated_failure2 = Repo.get(Media.VideoFailure, failure2.id)

          assert updated_failure1.resolved == true
          assert updated_failure1.resolved_at != nil
          assert updated_failure2.resolved == true
          assert updated_failure2.resolved_at != nil
        end)
    end
  end
end
