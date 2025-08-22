defmodule Reencodarr.AbAv1.CrfSearch.PatternMatchingTest do
  @moduledoc """
  Tests for regex pattern matching in CRF search output parsing.
  Validates pattern matching against real ab-av1 output fixtures.
  """
  use Reencodarr.DataCase, async: true

  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  a          # Video should be marked as failed
          updated_video = Repo.get!(Video, video.id)
          assert updated_video.state == :faileds Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  describe "process_line/3 pattern matching" do
    setup do
      {:ok, video} =
        Media.create_video(%{
          id: 1,
          path: "test_path.mkv",
          size: 1_000_000_000,
          service_id: "test",
          service_type: :sonarr
        })

      # Read fixture files
      crf_search_lines =
        Path.join([__DIR__, "..", "..", "..", "fixtures", "crf-search-output.txt"])
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      encoding_lines =
        Path.join([__DIR__, "..", "..", "..", "fixtures", "encoding-output.txt"])
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      %{video: video, crf_search_lines: crf_search_lines, encoding_lines: encoding_lines}
    end

    test "matches simple VMAF pattern", %{video: video, crf_search_lines: lines} do
      # Use the first sample VMAF line from fixture
      line = Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 28 VMAF 91.33"))

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      CrfSearch.process_line(line, video, [])
      assert Repo.aggregate(Vmaf, :count, :id) == 1

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
      assert vmaf.percent == 4.0
    end

    test "matches extended VMAF pattern with file size prediction", %{
      video: video,
      crf_search_lines: lines
    } do
      # Use a line with predicted video stream size from fixture
      line =
        Enum.find(
          lines,
          &String.contains?(&1, "crf 28 VMAF 90.52 predicted video stream size 253.42 MiB")
        )

      CrfSearch.process_line(line, video, [])

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 90.52
      assert vmaf.percent == 3.0
    end

    test "matches simple VMAF without percentage", %{video: video, crf_search_lines: lines} do
      # Use dash pattern line from fixture
      line = Enum.find(lines, &String.contains?(&1, "- crf 28 VMAF 90.52"))

      CrfSearch.process_line(line, video, [])

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 90.52
      assert vmaf.percent == 3.0
    end

    test "matches success pattern and marks chosen VMAF", %{video: video, crf_search_lines: lines} do
      # First add a VMAF record using the crf line from fixture
      crf_line =
        "crf 23.1 VMAF 95.14 predicted video stream size 439.91 MiB (4%) taking 31 minutes"

      CrfSearch.process_line(crf_line, video, [])

      # Then process success line from fixture
      success_line = Enum.find(lines, &String.contains?(&1, "crf 23.1 successful"))

      CrfSearch.process_line(success_line, video, [])

      # Should update the VMAF as chosen
      vmaf = Repo.one(Vmaf)
      assert vmaf.chosen == true
      assert vmaf.crf == 23.1
    end

    test "matches warning patterns", %{video: video} do
      warning_lines = [
        "Warning: you may want to set a max-crf to prevent really low quality encodes",
        "Warning: target VMAF (95) not reached for any CRF"
      ]

      Enum.each(warning_lines, fn line ->
        log =
          capture_log(fn ->
            CrfSearch.process_line(line, video, [])
          end)

        # Warning lines should now be handled properly and not generate "No match" errors
        refute log =~ "No match for line"
      end)
    end

    test "matches error patterns", %{video: video} do
      # Test the specific error pattern that the system handles
      specific_error = "Error: Failed to find a suitable crf"

      log =
        capture_log(fn ->
          CrfSearch.process_line(specific_error, video, [])
        end)

      assert log =~ "Failed to find a suitable CRF"

      # Check that the video was marked as failed
      updated_video = Repo.get!(Video, video.id)
      assert updated_video.state == :failed
    end

    test "handles decimal CRF values", %{video: video, crf_search_lines: lines} do
      # Use decimal CRF line from fixture
      line = Enum.find(lines, &String.contains?(&1, "- crf 17.2 VMAF 97.68"))

      CrfSearch.process_line(line, video, [])

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 17.2
      assert vmaf.score == 97.68
      assert vmaf.percent == 9.0
    end

    test "handles high precision VMAF scores", %{video: video, crf_search_lines: lines} do
      # Use high precision VMAF line from fixture
      line = Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 28 VMAF 91.33"))

      CrfSearch.process_line(line, video, [])

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
    end

    test "ignores non-matching lines", %{video: video} do
      non_matching_lines = [
        "Starting CRF search...",
        "Analyzing video properties",
        "Some random log message",
        "Progress: 50% complete"
      ]

      _log =
        capture_log(fn ->
          Enum.each(non_matching_lines, fn line ->
            CrfSearch.process_line(line, video, [])
          end)

          # Should not create any VMAF records
          assert Repo.aggregate(Vmaf, :count, :id) == 0
        end)
    end

    test "handles target VMAF parameter in success pattern", %{
      video: video,
      crf_search_lines: lines
    } do
      # Add VMAF first using dash pattern from fixture
      line1 = Enum.find(lines, &String.contains?(&1, "- crf 21.2 VMAF 96.23"))
      CrfSearch.process_line(line1, video, [], 96)

      # Process success with target VMAF from fixture - use matching CRF 21.2
      success_line = Enum.find(lines, &String.contains?(&1, "crf 21.2 successful"))
      CrfSearch.process_line(success_line, video, [], 96)

      vmaf = Repo.one(Vmaf)
      assert vmaf.chosen == true
    end

    test "validates CRF range boundaries", %{video: video, crf_search_lines: lines} do
      # Use actual lines from fixture with different CRF values
      edge_case_lines = [
        Enum.find(lines, &String.contains?(&1, "- crf 17.2 VMAF 97.68")),
        Enum.find(lines, &String.contains?(&1, "- crf 28 VMAF 90.52")),
        Enum.find(lines, &String.contains?(&1, "- crf 22.7 VMAF 95.41"))
      ]

      Enum.each(edge_case_lines, fn line ->
        CrfSearch.process_line(line, video, [])
      end)

      vmafs = Repo.all(Vmaf) |> Enum.sort_by(& &1.crf)
      assert length(vmafs) == 3
      assert Enum.at(vmafs, 0).crf == 17.2
      assert Enum.at(vmafs, 1).crf == 22.7
      assert Enum.at(vmafs, 2).crf == 28.0
    end

    test "handles VMAF scores at boundaries", %{video: video, crf_search_lines: lines} do
      # Use different VMAF scores from fixture
      boundary_lines = [
        Enum.find(lines, &String.contains?(&1, "sample 4/5 crf 28 VMAF 88.88")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 17.2 VMAF 98.63")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 23.1 VMAF 95.94"))
      ]

      Enum.each(boundary_lines, fn line ->
        CrfSearch.process_line(line, video, [])
      end)

      vmafs = Repo.all(Vmaf) |> Enum.sort_by(& &1.score)
      assert length(vmafs) == 3
      assert Enum.at(vmafs, 0).score == 88.88
      assert Enum.at(vmafs, 1).score == 95.94
      assert Enum.at(vmafs, 2).score == 98.63
    end

    test "handles percentage edge cases", %{video: video, crf_search_lines: lines} do
      # Use different percentage values from fixture
      percentage_lines = [
        Enum.find(lines, &String.contains?(&1, "sample 4/5 crf 28 VMAF 88.88 (1%)")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 17.2 VMAF 98.63 (15%)")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 23.1 VMAF 95.94 (7%)"))
      ]

      Enum.each(percentage_lines, fn line ->
        CrfSearch.process_line(line, video, [])
      end)

      vmafs = Repo.all(Vmaf) |> Enum.sort_by(& &1.percent)
      assert length(vmafs) == 3
      assert Enum.at(vmafs, 0).percent == 1.0
      assert Enum.at(vmafs, 1).percent == 7.0
      assert Enum.at(vmafs, 2).percent == 15.0
    end

    test "handles malformed but parseable lines", %{video: video} do
      # Use a line that matches the simple_vmaf pattern which expects a timestamp
      slightly_malformed_line = "[2024-12-12T00:13:08Z INFO] crf 22 VMAF 94.50 (75%)"

      CrfSearch.process_line(slightly_malformed_line, video, [])

      # Should create one VMAF record
      vmafs = Repo.all(Vmaf)
      assert length(vmafs) == 1
      vmaf = hd(vmafs)
      assert vmaf.crf == 22.0
      assert vmaf.score == 94.50
      assert vmaf.percent == 75.0
    end

    test "processes multiple VMAF entries for same video", %{
      video: video,
      crf_search_lines: lines
    } do
      # Use multiple lines from fixture
      vmaf_lines = [
        Enum.find(lines, &String.contains?(&1, "- crf 28 VMAF 90.52")),
        Enum.find(lines, &String.contains?(&1, "- crf 17.2 VMAF 97.68")),
        Enum.find(lines, &String.contains?(&1, "- crf 21.2 VMAF 96.23")),
        Enum.find(lines, &String.contains?(&1, "- crf 22.7 VMAF 95.41"))
      ]

      Enum.each(vmaf_lines, fn line ->
        CrfSearch.process_line(line, video, [])
      end)

      vmafs = Repo.all(Vmaf) |> Enum.sort_by(& &1.crf)
      assert length(vmafs) == 4

      # Verify each VMAF was created correctly
      assert Enum.at(vmafs, 0).crf == 17.2
      assert Enum.at(vmafs, 1).crf == 21.2
      assert Enum.at(vmafs, 2).crf == 22.7
      assert Enum.at(vmafs, 3).crf == 28.0
    end
  end

  describe "large file size warnings" do
    setup do
      {:ok, video} =
        Media.create_video(%{
          id: 2,
          path: "large_test.mkv",
          # 20GB
          size: 20_000_000_000,
          service_id: "test",
          service_type: :sonarr
        })

      %{video: video}
    end

    test "warns about VMAFs exceeding 10GB during search", %{video: video} do
      # Use a large file size prediction from fixture or create realistic one
      large_size_line =
        "crf 18 VMAF 97.0 predicted video stream size 12.5 GB (75%) taking 4 hours"

      log =
        capture_log(fn ->
          CrfSearch.process_line(large_size_line, video, [])
        end)

      assert log =~ "CrfSearch: VMAF CRF 18 estimated file size (12.5 GB) exceeds 10GB limit"

      # Should still create the VMAF record
      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 18.0
      assert vmaf.score == 97.0
    end

    test "fails video when chosen VMAF exceeds 10GB limit", %{video: video} do
      _log =
        capture_log(fn ->
          # First create a large VMAF
          large_line = "crf 20 VMAF 96.0 predicted video stream size 11.0 GB (80%) taking 3 hours"
          CrfSearch.process_line(large_line, video, [])

          # Then mark it as successful
          success_line = "crf 20 successful"

          log =
            capture_log(fn ->
              CrfSearch.process_line(success_line, video, [])
            end)

          assert log =~ "CrfSearch: Chosen VMAF CRF 20 exceeds 10GB limit"
          assert log =~ "Marking as failed"

          # Video should be marked as failed
          updated_video = Repo.get(Media.Video, video.id)
          assert updated_video.failed == true
        end)
    end
  end
end
