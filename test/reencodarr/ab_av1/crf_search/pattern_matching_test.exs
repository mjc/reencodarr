defmodule Reencodarr.AbAv1.CrfSearch.PatternMatchingTest do
  @moduledoc """
  Tests for regex pattern matching in CRF search output parsing.
  Validates pattern matching against real ab-av1 output fixtures.
  """
  use Reencodarr.DataCase, async: true

  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  describe "process_line/3 pattern matching" do
    setup do
      {:ok, video} =
        Fixtures.video_fixture(%{
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

    test "matches simple VMAF pattern without creating a record", %{
      video: video,
      crf_search_lines: lines
    } do
      # Per-sample lines are recognized for progress display but not persisted
      line = Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 28 VMAF 91.33"))

      log = capture_log(fn -> CrfSearch.process_line(line, video, [], 95) end)

      refute log =~ "No match for line"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
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

      CrfSearch.process_line(line, video, [], 95)

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 90.52
      assert vmaf.percent == 3.0
    end

    test "matches simple VMAF without percentage without creating a record", %{
      video: video,
      crf_search_lines: lines
    } do
      # Dash-format lines (print_attempt output) are recognized but not persisted
      line = Enum.find(lines, &String.contains?(&1, "- crf 28 VMAF 90.52"))

      log = capture_log(fn -> CrfSearch.process_line(line, video, [], 95) end)

      refute log =~ "No match for line"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "matches success pattern and marks chosen VMAF", %{video: video, crf_search_lines: lines} do
      # First add a VMAF record using the crf line from fixture
      crf_line =
        "crf 23.1 VMAF 95.14 predicted video stream size 439.91 MiB (4%) taking 31 minutes"

      CrfSearch.process_line(crf_line, video, [], 95)

      # Then process success line from fixture
      success_line = Enum.find(lines, &String.contains?(&1, "crf 23.1 successful"))

      CrfSearch.process_line(success_line, video, [], 95)

      # Should mark the VMAF as chosen on the video
      vmaf = Repo.one(Vmaf)
      updated_video = Media.get_video!(video.id)
      assert updated_video.chosen_vmaf_id == vmaf.id
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
            CrfSearch.process_line(line, video, [], 95)
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
          CrfSearch.process_line(specific_error, video, [], 95)
        end)

      # handle_error_line detects the pattern — no "No match" error should appear.
      # Failure recording is deferred to the exit handler so the
      # retry cascade (narrowed → standard → reduced target) can decide.
      refute log =~ "No match for line"

      # Video should NOT be marked failed during output processing
      updated_video = Media.get_video!(video.id)
      refute updated_video.state == :failed
    end

    test "handles decimal CRF values in eta_vmaf lines", %{video: video, crf_search_lines: lines} do
      # Use the aggregate eta_vmaf line (not the dash print_attempt line)
      line =
        Enum.find(
          lines,
          &String.contains?(&1, "crf 17.2 VMAF 97.68 predicted video stream size")
        )

      CrfSearch.process_line(line, video, [], 95)

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 17.2
      assert vmaf.score == 97.68
      assert vmaf.percent == 9.0
    end

    test "handles high precision VMAF scores in eta_vmaf lines", %{
      video: video,
      crf_search_lines: lines
    } do
      # Per-sample lines no longer create records; use aggregate eta_vmaf line
      line =
        Enum.find(
          lines,
          &String.contains?(&1, "crf 28 VMAF 90.52 predicted video stream size")
        )

      CrfSearch.process_line(line, video, [], 95)

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 90.52
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
            CrfSearch.process_line(line, video, [], 95)
          end)

          # Should not create any VMAF records
          assert Repo.aggregate(Vmaf, :count, :id) == 0
        end)
    end

    test "handles target VMAF parameter in success pattern", %{
      video: video,
      crf_search_lines: lines
    } do
      # Insert VMAF using the aggregate eta_vmaf line (not the dash print_attempt line)
      line1 =
        Enum.find(
          lines,
          &String.contains?(&1, "crf 21.2 VMAF 96.23 predicted video stream size")
        )

      CrfSearch.process_line(line1, video, [], 96)

      # Process success line — should mark the record chosen
      success_line = Enum.find(lines, &String.contains?(&1, "crf 21.2 successful"))
      CrfSearch.process_line(success_line, video, [], 96)

      vmaf = Repo.one(Vmaf)
      updated_video = Media.get_video!(video.id)
      assert updated_video.chosen_vmaf_id == vmaf.id
    end

    test "validates CRF range boundaries", %{video: video, crf_search_lines: lines} do
      # Use eta_vmaf (aggregate) lines from fixture — only these create records
      edge_case_lines = [
        Enum.find(
          lines,
          &String.contains?(&1, "crf 17.2 VMAF 97.68 predicted video stream size")
        ),
        Enum.find(lines, &String.contains?(&1, "crf 28 VMAF 90.52 predicted video stream size")),
        Enum.find(lines, &String.contains?(&1, "crf 22.7 VMAF 95.41 predicted video stream size"))
      ]

      Enum.each(edge_case_lines, fn line ->
        CrfSearch.process_line(line, video, [], 95)
      end)

      vmafs = Repo.all(Vmaf) |> Enum.sort_by(& &1.crf)
      assert length(vmafs) == 3
      assert Enum.at(vmafs, 0).crf == 17.2
      assert Enum.at(vmafs, 1).crf == 22.7
      assert Enum.at(vmafs, 2).crf == 28.0
    end

    test "handles VMAF scores at boundaries without creating records", %{
      video: video,
      crf_search_lines: lines
    } do
      # Per-sample lines are recognized for progress display but not persisted
      boundary_lines = [
        Enum.find(lines, &String.contains?(&1, "sample 4/5 crf 28 VMAF 88.88")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 17.2 VMAF 98.63")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 23.1 VMAF 95.94"))
      ]

      log =
        capture_log(fn ->
          Enum.each(boundary_lines, fn line ->
            CrfSearch.process_line(line, video, [], 95)
          end)
        end)

      refute log =~ "No match for line"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "handles percentage edge cases without creating records", %{
      video: video,
      crf_search_lines: lines
    } do
      # Per-sample lines are recognized for progress display but not persisted
      percentage_lines = [
        Enum.find(lines, &String.contains?(&1, "sample 4/5 crf 28 VMAF 88.88 (1%)")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 17.2 VMAF 98.63 (15%)")),
        Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 23.1 VMAF 95.94 (7%)"))
      ]

      log =
        capture_log(fn ->
          Enum.each(percentage_lines, fn line ->
            CrfSearch.process_line(line, video, [], 95)
          end)
        end)

      refute log =~ "No match for line"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "handles malformed but parseable lines without creating records", %{video: video} do
      # simple_vmaf lines (even with timestamps) are recognized but not persisted
      slightly_malformed_line = "[2024-12-12T00:13:08Z INFO] crf 22 VMAF 94.50 (75%)"

      log = capture_log(fn -> CrfSearch.process_line(slightly_malformed_line, video, [], 95) end)

      refute log =~ "No match for line"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "processes multiple VMAF entries for same video", %{
      video: video,
      crf_search_lines: lines
    } do
      # Use eta_vmaf (aggregate) lines from fixture — only these create records
      vmaf_lines = [
        Enum.find(lines, &String.contains?(&1, "crf 28 VMAF 90.52 predicted video stream size")),
        Enum.find(
          lines,
          &String.contains?(&1, "crf 17.2 VMAF 97.68 predicted video stream size")
        ),
        Enum.find(
          lines,
          &String.contains?(&1, "crf 21.2 VMAF 96.23 predicted video stream size")
        ),
        Enum.find(lines, &String.contains?(&1, "crf 22.7 VMAF 95.41 predicted video stream size"))
      ]

      Enum.each(vmaf_lines, fn line ->
        CrfSearch.process_line(line, video, [], 95)
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
        Fixtures.video_fixture(%{
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
          CrfSearch.process_line(large_size_line, video, [], 95)
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
          CrfSearch.process_line(large_line, video, [], 95)

          # Then mark it as successful
          success_line = "crf 20 successful"

          log =
            capture_log(fn ->
              CrfSearch.process_line(success_line, video, [], 95)
            end)

          assert log =~ "CrfSearch: Chosen VMAF CRF 20.0 exceeds 10GB limit"
          assert log =~ "Marking as failed"

          # Video should be marked as failed
          updated_video = Repo.get(Media.Video, video.id)
          assert updated_video.state == :failed
        end)
    end
  end
end
