defmodule Reencodarr.FailureTrackingIntegrationTest do
  use Reencodarr.DataCase

  import Reencodarr.MediaFixtures
  alias Reencodarr.{FailureTracker, FailureReporting}

  describe "failure tracking integration" do
    test "end-to-end failure tracking and reporting" do
      # Create some test videos
      video1 = video_fixture(%{title: "Test Video 1", path: "/path/to/video1.mkv"})
      video2 = video_fixture(%{title: "Test Video 2", path: "/path/to/video2.mkv"})
      video3 = video_fixture(%{title: "Test Video 3", path: "/path/to/video3.mkv"})

      # Record various types of failures
      FailureTracker.record_file_access_failure(video1, "File not found")
      FailureTracker.record_mediainfo_failure(video1, "Invalid JSON output")

      FailureTracker.record_vmaf_calculation_failure(video2, "ab-av1 crashed")
      FailureTracker.record_crf_optimization_failure(video2, 95.0, [{23, 94.2}, {25, 96.1}])

      FailureTracker.record_process_failure(video3, 1)
      FailureTracker.record_timeout_failure(video3, "30 minutes")

      # Generate a failure report
      report = FailureReporting.generate_failure_report()

      # Verify report structure
      assert is_map(report)
      assert Map.has_key?(report, :summary)
      assert Map.has_key?(report, :by_stage)
      assert Map.has_key?(report, :by_category)
      assert Map.has_key?(report, :common_patterns)
      assert Map.has_key?(report, :recommendations)

      # Verify summary data
      summary = report.summary
      assert summary.total_failures >= 6

      # Verify stage breakdown
      by_stage = report.by_stage
      assert is_list(by_stage)
      assert length(by_stage) >= 3

      # Find each stage in the list
      analysis_stage = Enum.find(by_stage, &(&1.stage == :analysis))
      crf_search_stage = Enum.find(by_stage, &(&1.stage == :crf_search))
      encoding_stage = Enum.find(by_stage, &(&1.stage == :encoding))

      # Check that we have failures in each stage
      assert analysis_stage.total_count >= 2
      assert crf_search_stage.total_count >= 2
      assert encoding_stage.total_count >= 2

      # Print the report for manual verification
      IO.puts("\n=== INTEGRATION TEST FAILURE REPORT ===")
      FailureReporting.print_failure_report()
    end
  end
end
