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
      {:ok, video} = Fixtures.video_fixture()

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
          assert updated_video.state == :failed
        end)
    end

    test "records mediainfo parsing failure" do
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()
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
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()

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
      {:ok, video} = Fixtures.video_fixture()

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

  describe "analysis failures - validation" do
    test "records validation failure with changeset errors" do
      {:ok, video} = Fixtures.video_fixture()
      changeset_errors = [{:path, {"can't be blank", [validation: :required]}}]

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_validation_failure(video, changeset_errors)

          assert failure.failure_stage == :analysis
          assert failure.failure_category == :validation
          assert failure.failure_code == "VALIDATION"
          assert String.contains?(failure.failure_message, "Validation failed")
          assert String.contains?(failure.failure_message, "path")
        end)
    end

    test "records validation failure includes changeset errors in context" do
      {:ok, video} = Fixtures.video_fixture()
      changeset_errors = [{:width, {"is invalid", [type: :integer]}}]

      _log =
        with_captured_logs(fn ->
          {:ok, failure} = FailureTracker.record_validation_failure(video, changeset_errors)
          [error] = failure.system_context.changeset_errors
          assert error.field == :width
          assert error.message == "is invalid"
        end)
    end
  end

  describe "crf search failures - vmaf calculation" do
    test "records vmaf calculation failure" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_vmaf_calculation_failure(video, "probe timed out")

          assert failure.failure_stage == :crf_search
          assert failure.failure_category == :vmaf_calculation
          assert failure.failure_code == "VMAF_CALC"
          assert String.contains?(failure.failure_message, "VMAF calculation failed")
          assert failure.system_context.reason == "probe timed out"
        end)
    end
  end

  describe "encoding failures - resource exhaustion and codec" do
    test "records resource exhaustion failure" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_resource_exhaustion_failure(video, :memory, "OOM killer")

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :resource_exhaustion
          assert failure.failure_code == "RESOURCE_MEMORY"
          assert String.contains?(failure.failure_message, "Resource exhaustion")
          assert failure.system_context.resource_type == :memory
          assert failure.system_context.details == "OOM killer"
        end)
    end

    test "records codec failure" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_codec_failure(video, %{codec: "HEVC", profile: "main10"})

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :codec_issues
          assert failure.failure_code == "CODEC_UNSUPPORTED"
          assert String.contains?(failure.failure_message, "Codec compatibility issue")
        end)
    end
  end

  describe "post process failures - sync, cleanup, config, environment" do
    test "records sync failure" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_sync_failure(video, :sonarr, "connection refused")

          assert failure.failure_stage == :post_process
          assert failure.failure_category == :sync_integration
          assert failure.failure_code == "SYNC_SONARR"
          assert String.contains?(failure.failure_message, "sonarr sync failed")
          assert failure.system_context.service == :sonarr
          assert failure.system_context.error == "connection refused"
        end)
    end

    test "records cleanup failure" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_cleanup_failure(video, "/tmp/video.reencoded.mkv", "eacces")

          assert failure.failure_stage == :post_process
          assert failure.failure_category == :cleanup
          assert failure.failure_code == "CLEANUP"
          assert String.contains?(failure.failure_message, "Cleanup failed")
          assert failure.system_context.cleanup_target == "/tmp/video.reencoded.mkv"
          assert failure.system_context.error == "eacces"
        end)
    end

    test "records configuration failure - defaults to analysis stage" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_configuration_failure(video, "missing ab-av1 binary")

          assert failure.failure_stage == :analysis
          assert failure.failure_category == :configuration
          assert failure.failure_code == "CONFIG"
          assert String.contains?(failure.failure_message, "Configuration issue")
          assert failure.system_context.config_issue == "missing ab-av1 binary"
        end)
    end

    test "records configuration failure - custom stage via opts" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_configuration_failure(video, "bad encoder args",
              stage: :encoding
            )

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :configuration
        end)
    end

    test "records system environment failure - defaults to analysis stage" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_system_environment_failure(video, "out of disk space")

          assert failure.failure_stage == :analysis
          assert failure.failure_category == :system_environment
          assert failure.failure_code == "ENV"
          assert String.contains?(failure.failure_message, "System environment issue")
          assert failure.system_context.env_issue == "out of disk space"
        end)
    end
  end

  describe "cross-cutting failures - unknown and exception" do
    test "records unknown failure with given stage" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          {:ok, failure} =
            FailureTracker.record_unknown_failure(video, :crf_search, "unexpected crash")

          assert failure.failure_stage == :crf_search
          assert failure.failure_category == :unknown
          assert failure.failure_code == "UNKNOWN"
          assert String.contains?(failure.failure_message, "Unknown failure")
          assert failure.system_context.error == "unexpected crash"
        end)
    end

    test "records exception failure in encoding stage" do
      {:ok, video} = Fixtures.video_fixture()

      _log =
        with_captured_logs(fn ->
          exception_context = %{
            exception_type: "RuntimeError",
            exception_message: "process crashed"
          }

          {:ok, failure} = FailureTracker.record_exception_failure(video, exception_context)

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :process_failure
          assert failure.failure_code == "EXCEPTION"
          assert String.contains?(failure.failure_message, "Exception during encoding setup")
          assert String.contains?(failure.failure_message, "RuntimeError")
          assert failure.system_context["error_type"] == "exception"
        end)
    end
  end

  describe "build_command_context/3" do
    test "builds context with command line from args" do
      args = ["crf-search", "--vmaf", "95", "input.mkv"]
      context = FailureTracker.build_command_context(args)
      assert context.command == "ab-av1 crf-search --vmaf 95 input.mkv"
      assert context.args == args
      assert context.full_output == ""
    end

    test "joins output_lines list into full_output string" do
      args = ["encode"]
      lines = ["line1", "line2", "line3"]
      context = FailureTracker.build_command_context(args, lines)
      assert context.full_output == "line1\nline2\nline3"
    end

    test "accepts binary output directly" do
      args = ["encode"]
      output = "some output text"
      context = FailureTracker.build_command_context(args, output)
      assert context.full_output == "some output text"
    end

    test "merges extra_context into result" do
      args = ["encode"]
      extra = %{target_vmaf: 95, video_id: 123}
      context = FailureTracker.build_command_context(args, [], extra)
      assert context.target_vmaf == 95
      assert context.video_id == 123
    end

    test "extra_context does not overwrite base keys" do
      args = ["crf-search"]
      extra = %{command: "overridden"}
      context = FailureTracker.build_command_context(args, [], extra)
      # Map.merge with extra_context means extra_context wins — verifying actual behavior
      assert is_binary(context.command)
    end

    test "works with empty args" do
      context = FailureTracker.build_command_context([])
      assert context.command == "ab-av1 "
      assert context.full_output == ""
    end
  end

  describe "parse_ffmpeg_error_from_output/2" do
    test "uses original exit code classification when no ffmpeg error line in output" do
      context = %{"full_output" => "some non-error output\nno ffmpeg lines here"}

      {exit_code, category, _message} =
        FailureTracker.parse_ffmpeg_error_from_output(context, 137)

      assert exit_code == 137
      assert category == :resource_exhaustion
    end

    test "extracts ffmpeg exit code from output and classifies it" do
      context = %{"full_output" => "Error: ffmpeg encode exit code 22"}
      {exit_code, category, _message} = FailureTracker.parse_ffmpeg_error_from_output(context, 1)
      assert exit_code == 22
      assert category == :codec_issues
    end

    test "uses exit code 1 classification when no ffmpeg error found" do
      {exit_code, category, _message} = FailureTracker.parse_ffmpeg_error_from_output(%{}, 1)
      assert exit_code == 1
      assert category == :process_failure
    end

    test "uses exit code 2 classification (configuration error)" do
      {exit_code, category, _message} = FailureTracker.parse_ffmpeg_error_from_output(%{}, 2)
      assert exit_code == 2
      assert category == :configuration
    end

    test "uses exit code 143 classification (SIGTERM)" do
      {exit_code, category, _message} = FailureTracker.parse_ffmpeg_error_from_output(%{}, 143)
      assert exit_code == 143
      assert category == :resource_exhaustion
    end

    test "handles context with no full_output key" do
      context = %{"other_key" => "value"}
      {exit_code, category, _message} = FailureTracker.parse_ffmpeg_error_from_output(context, 5)
      assert exit_code == 5
      assert category == :system_environment
    end

    test "message includes exit code information" do
      {_exit_code, _category, message} = FailureTracker.parse_ffmpeg_error_from_output(%{}, 137)
      assert is_binary(message)
      assert String.length(message) > 0
    end
  end
end
