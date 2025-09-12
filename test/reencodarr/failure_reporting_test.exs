defmodule Reencodarr.FailureReportingTest do
  use Reencodarr.DataCase
  import ExUnit.CaptureLog

  alias Reencodarr.{FailureReporting, FailureTracker}
  alias Reencodarr.Media.VideoFailure

  describe "failure summary" do
    test "generates summary with no failures" do
      summary = FailureReporting.get_failure_summary(7)

      assert summary.total_failures == 0
      assert summary.resolved_failures == 0
      assert summary.unresolved_failures == 0
      assert summary.resolution_rate_percent == 0.0
      assert summary.period_days == 7
    end

    test "generates summary with mixed resolved/unresolved failures" do
      {:ok, video1} = Fixtures.video_fixture()
      {:ok, video2} = Fixtures.video_fixture()

      # Create some failures and capture their logs to suppress warnings
      _log =
        capture_log(fn ->
          {:ok, failure1} = FailureTracker.record_file_access_failure(video1, "Error 1")
          {:ok, _failure2} = FailureTracker.record_mediainfo_failure(video2, "Error 2")

          # Resolve one failure
          VideoFailure.resolve_failure(failure1)

          summary = FailureReporting.get_failure_summary(7)

          assert summary.total_failures == 2
          assert summary.resolved_failures == 1
          assert summary.unresolved_failures == 1
          assert summary.resolution_rate_percent == 50.0
        end)
    end
  end

  describe "failures by stage" do
    test "groups failures by processing stage" do
      {:ok, video} = Fixtures.video_fixture()

      # Create failures in different stages
      _log =
        capture_log(fn ->
          {:ok, _} = FailureTracker.record_file_access_failure(video, "Analysis error")
          {:ok, _} = FailureTracker.record_crf_optimization_failure(video, 95.0, [])
          {:ok, _} = FailureTracker.record_process_failure(video, 1)

          by_stage = FailureReporting.get_failures_by_stage(7)

          assert length(by_stage) == 3

          # Find each stage
          analysis_stage = Enum.find(by_stage, &(&1.stage == :analysis))
          crf_stage = Enum.find(by_stage, &(&1.stage == :crf_search))
          encoding_stage = Enum.find(by_stage, &(&1.stage == :encoding))

          assert analysis_stage.total_count == 1
          assert crf_stage.total_count == 1
          assert encoding_stage.total_count == 1
        end)
    end
  end

  describe "failures by category" do
    test "groups failures by category across stages" do
      {:ok, video} = Fixtures.video_fixture()

      # Create failures in same category but different stages
      _log =
        capture_log(fn ->
          {:ok, _} = FailureTracker.record_file_access_failure(video, "Analysis error")

          {:ok, _} =
            FailureTracker.record_file_operation_failure(video, :move, "src", "dst", "error")

          by_category = FailureReporting.get_failures_by_category(7)

          file_access_cat = Enum.find(by_category, &(&1.category == :file_access))
          file_ops_cat = Enum.find(by_category, &(&1.category == :file_operations))

          assert file_access_cat.total_count == 1
          assert file_ops_cat.total_count == 1
        end)
    end
  end

  describe "recommendations" do
    test "generates recommendations for high failure rates" do
      {:ok, video} = Fixtures.video_fixture()

      # Create many failures in encoding stage to trigger recommendation
      _log =
        capture_log(fn ->
          Enum.each(1..15, fn i ->
            FailureTracker.record_process_failure(video, 1, context: %{iteration: i})
          end)

          recommendations = FailureReporting.generate_recommendations(7)

          # Should have recommendation about high failure stage
          high_failure_rec =
            Enum.find(
              recommendations,
              &(&1.category == :stage_failures)
            )

          assert high_failure_rec != nil
          assert high_failure_rec.priority == :high
          assert String.contains?(high_failure_rec.description, "encoding")
        end)
    end

    test "generates recommendations for resource exhaustion" do
      {:ok, video} = Fixtures.video_fixture()

      # Create multiple resource exhaustion failures
      _log =
        capture_log(fn ->
          Enum.each(1..5, fn _i ->
            FailureTracker.record_resource_exhaustion_failure(video, :memory, "OOM")
          end)

          recommendations = FailureReporting.generate_recommendations(7)

          # Should have recommendation about resource issues
          resource_rec =
            Enum.find(
              recommendations,
              &(&1.category == :resource_exhaustion)
            )

          assert resource_rec != nil
          assert resource_rec.priority == :high
          assert String.contains?(resource_rec.description, "resource exhaustion")
        end)
    end
  end

  describe "full report generation" do
    test "generates comprehensive report" do
      {:ok, video} = Fixtures.video_fixture()

      # Create various failures
      _log =
        capture_log(fn ->
          {:ok, _} = FailureTracker.record_file_access_failure(video, "File error")
          {:ok, _} = FailureTracker.record_crf_optimization_failure(video, 95.0, [])
          {:ok, _} = FailureTracker.record_process_failure(video, 137)

          report = FailureReporting.generate_failure_report(days_back: 7, limit: 5)

          assert report.summary.total_failures == 3
          assert length(report.by_stage) == 3
          assert length(report.by_category) == 3
          assert length(report.common_patterns) <= 5
          assert is_list(report.recent_failures)
          assert is_number(report.resolution_rate) or is_nil(report.resolution_rate)
          assert is_list(report.recommendations)
        end)
    end

    test "filters critical failures correctly" do
      {:ok, video} = Fixtures.video_fixture()

      # Create some critical failures
      _log =
        capture_log(fn ->
          FailureTracker.record_resource_exhaustion_failure(video, :memory, "OOM")
          FailureTracker.record_timeout_failure(video, "30 minutes")
          # Non-critical
          FailureTracker.record_file_access_failure(video, "File not found")

          critical = FailureReporting.get_critical_failures()

          assert length(critical) == 2
          assert Enum.any?(critical, &(&1.category == :resource_exhaustion))
          assert Enum.any?(critical, &(&1.category == :timeout))
          refute Enum.any?(critical, &(&1.category == :file_access))
        end)
    end
  end
end
