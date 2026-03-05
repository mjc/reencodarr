defmodule Reencodarr.Core.ProgressTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Core.Progress

  describe "calculate_percentage/1" do
    test "calculates correctly with completed and total" do
      assert Progress.calculate_percentage(completed: 50, total: 100) == 50.0
    end

    test "returns 0.0 when total is 0" do
      assert Progress.calculate_percentage(completed: 10, total: 0) == 0.0
    end

    test "returns 0.0 with default opts" do
      assert Progress.calculate_percentage([]) == 0.0
    end

    test "rounds to 1 decimal place" do
      assert Progress.calculate_percentage(completed: 1, total: 3) == 33.3
    end

    test "returns 100.0 when complete" do
      assert Progress.calculate_percentage(completed: 7, total: 7) == 100.0
    end

    test "allows over 100% (no capping)" do
      result = Progress.calculate_percentage(completed: 110, total: 100)
      assert result == 110.0
    end
  end

  describe "format_progress/1" do
    test "formats percent and eta" do
      result = Progress.format_progress(%{percent: 75.5, eta: "5 minutes"})
      assert result == "75.5% complete (ETA: 5 minutes)"
    end

    test "handles missing percent with default 0" do
      result = Progress.format_progress(%{eta: "10 minutes"})
      assert result == "0% complete (ETA: 10 minutes)"
    end

    test "handles missing eta with default unknown" do
      result = Progress.format_progress(%{percent: 50})
      assert result == "50% complete (ETA: unknown)"
    end

    test "handles empty map" do
      result = Progress.format_progress(%{})
      assert result == "0% complete (ETA: unknown)"
    end
  end

  describe "update_progress/2" do
    test "adds a new job to empty progress" do
      result = Progress.update_progress(%{active_jobs: []}, %{job_id: 1, percent: 50})
      assert result.active_jobs == [%{job_id: 1, percent: 50}]
    end

    test "adds a new job when no active_jobs key exists" do
      result = Progress.update_progress(%{}, %{job_id: 1, percent: 10})
      assert length(result.active_jobs) == 1
    end

    test "updates an existing job with matching job_id" do
      initial = %{active_jobs: [%{job_id: 1, percent: 10}]}
      updated = Progress.update_progress(initial, %{job_id: 1, percent: 80})
      assert length(updated.active_jobs) == 1
      assert hd(updated.active_jobs).percent == 80
    end

    test "adds a new job when job_id differs" do
      initial = %{active_jobs: [%{job_id: 1, percent: 10}]}
      updated = Progress.update_progress(initial, %{job_id: 2, percent: 20})
      assert length(updated.active_jobs) == 2
    end

    test "falls back to 'default' key when no identifier field" do
      result1 = Progress.update_progress(%{active_jobs: []}, %{percent: 10})
      result2 = Progress.update_progress(result1, %{percent: 50})
      # Both keyed as "default" — update in place
      assert length(result2.active_jobs) == 1
      assert hd(result2.active_jobs).percent == 50
    end

    test "uses filename as fallback job key" do
      job1 = %{filename: "video1.mkv", percent: 10}
      job2 = %{filename: "video2.mkv", percent: 20}
      result = Progress.update_progress(%{active_jobs: [job1]}, job2)
      assert length(result.active_jobs) == 2
    end
  end
end
