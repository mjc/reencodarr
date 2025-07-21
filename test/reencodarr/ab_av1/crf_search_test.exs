defmodule Reencodarr.AbAv1.CrfSearchTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  import Reencodarr.MediaFixtures
  import ExUnit.CaptureLog

  describe "process_line/3" do
    setup do
      video = video_fixture(%{path: "/test/video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "creates VMAF record for valid line", %{video: video} do
      line = sample_vmaf_line(crf: 28, score: 91.33)

      assert_database_state(Vmaf, 1, fn ->
        CrfSearch.process_line(line, video, [])
      end)

      vmaf = Repo.one(Vmaf)
      assert vmaf.video_id == video.id
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
    end

    test "does not create VMAF record for invalid line", %{video: video} do
      line = invalid_sample_line()

      assert_database_state(Vmaf, 0, fn ->
        CrfSearch.process_line(line, video, [])
      end)
    end

    test "parses multiple lines from fixture file", %{video: video} do
      lines = load_sample_crf_output()

      # Based on actual fixture content
      assert_database_state(Vmaf, 16, fn ->
        Enum.each(lines, fn line ->
          CrfSearch.process_line(line, video, [])
        end)
      end)

      # Verify the created records have expected properties
      vmafs = Repo.all(from v in Vmaf, order_by: v.crf)
      assert length(vmafs) == 16

      # Scores should generally decrease with higher CRF
      crf_values = Enum.map(vmafs, & &1.crf)
      assert crf_values == Enum.sort(crf_values)
    end

    # Helper functions for test data generation
    defp sample_vmaf_line(opts) do
      crf = Keyword.get(opts, :crf, 28)
      score = Keyword.get(opts, :score, 91.33)
      sample = Keyword.get(opts, :sample, 1)
      progress = Keyword.get(opts, :progress, "4%")

      "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample #{sample}/5 crf #{crf} VMAF #{score} (#{progress})"
    end

    defp invalid_sample_line do
      "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] encoding sample 1/5 crf 28"
    end

    defp load_sample_crf_output do
      "test/fixtures/crf-search-output.txt"
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
    end
  end

  describe "enhanced error handling" do
    setup do
      video = %{id: 2, path: "test_error_path", size: 100}
      {:ok, video} = Media.create_video(video)
      %{video: video}
    end

    test "provides detailed error message when no VMAF scores are found", %{video: video} do
      error_line = "Error: Failed to find a suitable crf"

      # Capture logs to verify the detailed error message
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          CrfSearch.process_line(error_line, video, [], 95)
        end)

      assert log =~
               "Failed to find a suitable CRF for #{Path.basename(video.path)} (target VMAF: 95)"

      assert log =~ "No VMAF scores were recorded"
      assert log =~ "encoding samples failed completely"
    end

    test "provides detailed error message when few VMAF scores are found", %{video: video} do
      # Create a couple of VMAF scores for the video
      {:ok, _vmaf1} = Media.create_vmaf(%{video_id: video.id, crf: 22.0, score: 88.5, params: []})
      {:ok, _vmaf2} = Media.create_vmaf(%{video_id: video.id, crf: 18.0, score: 92.3, params: []})

      error_line = "Error: Failed to find a suitable crf"

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          CrfSearch.process_line(error_line, video, [], 95)
        end)

      assert log =~
               "Failed to find a suitable CRF for #{Path.basename(video.path)} (target VMAF: 95)"

      assert log =~ "Only 2 VMAF score(s) were tested"
      assert log =~ "highest: 92.3"
      assert log =~ "search space may be too limited"
    end

    test "provides detailed error message when target cannot be reached", %{video: video} do
      # Create several VMAF scores that are all below the target
      {:ok, _vmaf1} = Media.create_vmaf(%{video_id: video.id, crf: 28.0, score: 85.0, params: []})
      {:ok, _vmaf2} = Media.create_vmaf(%{video_id: video.id, crf: 22.0, score: 88.5, params: []})
      {:ok, _vmaf3} = Media.create_vmaf(%{video_id: video.id, crf: 18.0, score: 92.3, params: []})
      {:ok, _vmaf4} = Media.create_vmaf(%{video_id: video.id, crf: 15.0, score: 94.1, params: []})

      error_line = "Error: Failed to find a suitable crf"

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          CrfSearch.process_line(error_line, video, [], 96)
        end)

      assert log =~
               "Failed to find a suitable CRF for #{Path.basename(video.path)} (target VMAF: 96)"

      assert log =~ "Tested 4 CRF values"
      assert log =~ "VMAF scores ranging from 85.0 to 94.1"
      assert log =~ "highest quality (94.1) is still 1.9 points below the target"
      assert log =~ "Try lowering the target VMAF"
    end
  end

  describe "savings calculation" do
    setup do
      video = %{id: 3, path: "test_savings_path", size: 1_000_000_000}
      {:ok, video} = Media.create_video(video)
      %{video: video}
    end

    test "calculates savings correctly for VMAF records with percent data", %{video: video} do
      # Test with 80% size (20% savings)
      line =
        "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf 25 VMAF 95.50 (80%)"

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      CrfSearch.process_line(line, video, [])

      assert Repo.aggregate(Vmaf, :count, :id) == 1
      vmaf = Repo.one(Vmaf)

      # Verify VMAF data
      assert vmaf.video_id == video.id
      assert vmaf.crf == 25.0
      assert vmaf.score == 95.50
      assert vmaf.percent == 80.0

      # Verify savings calculation: (100 - 80) / 100 * 1,000,000,000 = 200,000,000
      assert vmaf.savings == 200_000_000
    end

    test "calculates different savings for different percentages", %{video: video} do
      # Test multiple percentages
      test_cases = [
        # 50% savings
        {50, 500_000_000},
        # 25% savings
        {75, 250_000_000},
        # 10% savings
        {90, 100_000_000},
        # 5% savings
        {95, 50_000_000}
      ]

      Enum.each(test_cases, fn {percent, expected_savings} ->
        # Generate unique CRF values
        crf = 20.0 + percent / 10

        line =
          "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf #{crf} VMAF 95.00 (#{percent}%)"

        CrfSearch.process_line(line, video, [])

        vmaf = Repo.one(from v in Vmaf, where: v.crf == ^crf)

        assert vmaf.savings == expected_savings,
               "Expected savings #{expected_savings} for #{percent}% but got #{vmaf.savings}"
      end)
    end

    test "handles missing percent gracefully", %{video: video} do
      # Test direct upsert without percent
      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => 30.0,
          "score" => 90.0,
          "params" => []
        })

      # Should not crash and savings should be nil
      assert vmaf.savings == nil
    end

    test "calculates savings from Media.upsert_vmaf when percent is provided", %{video: video} do
      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => 28.0,
          "score" => 93.0,
          # 30% savings
          "percent" => "70",
          "params" => []
        })

      # Verify savings: (100 - 70) / 100 * 1,000,000,000 = 300,000,000
      assert vmaf.savings == 300_000_000
    end
  end

  describe "10GB size limit" do
    setup do
      video = %{id: 3, path: "test_large_video.mkv", size: 20_000_000_000}
      {:ok, video} = Media.create_video(video)
      %{video: video}
    end

    test "marks video as failed when chosen VMAF estimated size exceeds 10GB", %{video: video} do
      # First insert a VMAF that would exceed 10GB
      eta_line = "crf 23 VMAF 95.2 predicted video stream size 12.5 GB (75%) taking 3 hours"

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(eta_line, video, [], 95)
        end)

      assert log_output =~
               "CrfSearch: VMAF CRF 23 estimated file size (12.5 GB) exceeds 10GB limit"

      # Verify VMAF record was created (but not failed yet)
      vmaf_count = Repo.aggregate(Vmaf, :count, :id)
      assert vmaf_count == 1

      # Verify video is not failed yet
      reloaded_video = Repo.get(Media.Video, video.id)
      assert reloaded_video.failed == false

      # Now process the success line that marks this CRF as chosen
      success_line = "crf 23 successful"

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(success_line, video, [], 95)
        end)

      assert log_output =~ "CrfSearch: Chosen VMAF CRF 23 exceeds 10GB limit"
      assert log_output =~ "Marking as failed"

      # Now the video should be marked as failed
      final_video = Repo.get(Media.Video, video.id)
      assert final_video.failed == true

      # Verify the VMAF is still there and marked as chosen
      vmaf = Repo.one(Vmaf)
      assert vmaf.chosen == true
      assert vmaf.crf == 23.0
    end

    test "allows video when chosen VMAF estimated size is under 10GB", %{video: video} do
      # Insert a VMAF that would be under 10GB
      eta_line = "crf 25 VMAF 95.0 predicted video stream size 8.2 GB (60%) taking 2 hours"
      CrfSearch.process_line(eta_line, video, [], 95)

      # Process the success line
      success_line = "crf 25 successful"
      CrfSearch.process_line(success_line, video, [], 95)

      # Video should not be marked as failed
      reloaded_video = Repo.get(Media.Video, video.id)
      assert reloaded_video.failed == false

      # Verify VMAF record exists and is chosen
      vmaf_count = Repo.aggregate(Vmaf, :count, :id)
      assert vmaf_count == 1

      vmaf = Repo.one(Vmaf)
      assert vmaf.chosen == true
      assert vmaf.crf == 25.0
    end

    test "allows multiple VMAF records but only fails if chosen one exceeds limit", %{
      video: video
    } do
      # Insert multiple VMAFs, some over 10GB, some under
      eta_line1 = "crf 20 VMAF 96.0 predicted video stream size 15.0 GB (85%) taking 4 hours"
      eta_line2 = "crf 22 VMAF 95.5 predicted video stream size 12.0 GB (78%) taking 3.5 hours"
      eta_line3 = "crf 24 VMAF 95.0 predicted video stream size 9.5 GB (65%) taking 3 hours"

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(eta_line1, video, [], 95)
          CrfSearch.process_line(eta_line2, video, [], 95)
          CrfSearch.process_line(eta_line3, video, [], 95)
        end)

      # Check that warnings were logged for VMAFs exceeding 10GB
      assert log_output =~
               "CrfSearch: VMAF CRF 20 estimated file size (15.0 GB) exceeds 10GB limit"

      assert log_output =~
               "CrfSearch: VMAF CRF 22 estimated file size (12.0 GB) exceeds 10GB limit"

      # All VMAFs should be created
      vmaf_count = Repo.aggregate(Vmaf, :count, :id)
      assert vmaf_count == 3

      # Video should not be failed yet
      reloaded_video = Repo.get(Media.Video, video.id)
      assert reloaded_video.failed == false

      # Choose the one under 10GB (CRF 24)
      success_line = "crf 24 successful"
      CrfSearch.process_line(success_line, video, [], 95)

      # Video should not be failed
      final_video = Repo.get(Media.Video, video.id)
      assert final_video.failed == false

      # Verify the correct VMAF is chosen
      chosen_vmaf = Repo.one(from v in Vmaf, where: v.chosen == true)
      assert chosen_vmaf.crf == 24.0
    end

    test "fails video when chosen VMAF exceeds limit even with multiple options", %{video: video} do
      # Insert multiple VMAFs
      eta_line1 = "crf 20 VMAF 96.0 predicted video stream size 15.0 GB (85%) taking 4 hours"
      eta_line2 = "crf 22 VMAF 95.5 predicted video stream size 12.0 GB (78%) taking 3.5 hours"
      eta_line3 = "crf 24 VMAF 95.0 predicted video stream size 9.5 GB (65%) taking 3 hours"

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(eta_line1, video, [], 95)
          CrfSearch.process_line(eta_line2, video, [], 95)
          CrfSearch.process_line(eta_line3, video, [], 95)
        end)

      # Check that warnings were logged for VMAFs exceeding 10GB
      assert log_output =~
               "CrfSearch: VMAF CRF 20 estimated file size (15.0 GB) exceeds 10GB limit"

      assert log_output =~
               "CrfSearch: VMAF CRF 22 estimated file size (12.0 GB) exceeds 10GB limit"

      # Choose the one over 10GB (CRF 22)
      success_line = "crf 22 successful"

      log_output =
        capture_log(fn ->
          CrfSearch.process_line(success_line, video, [], 95)
        end)

      assert log_output =~ "CrfSearch: Chosen VMAF CRF 22 exceeds 10GB limit"
      assert log_output =~ "Marking as failed"

      # Video should be failed
      final_video = Repo.get(Media.Video, video.id)
      assert final_video.failed == true

      # Verify the correct VMAF is chosen
      chosen_vmaf = Repo.one(from v in Vmaf, where: v.chosen == true)
      assert chosen_vmaf.crf == 22.0
    end
  end
end
