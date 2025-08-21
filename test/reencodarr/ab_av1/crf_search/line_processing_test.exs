defmodule Reencodarr.AbAv1.CrfSearch.LineProcessingTest do
  @moduledoc """
  Tests for CRF search line processing and pattern matching functionality.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  import Reencodarr.MediaFixtures
  import ExUnit.CaptureLog

  describe "process_line/3 basic functionality" do
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

    test "handles invalid lines without error", %{video: video} do
      line = "Invalid line format"

      log =
        capture_log(fn ->
          CrfSearch.process_line(line, video, [])
        end)

      assert log =~ "No match for line"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "processes VMAF line with size and time information", %{video: video} do
      line = "crf 28 VMAF 91.33 predicted video stream size 800 MB (85%) taking 120 seconds"

      CrfSearch.process_line(line, video, ["--preset", "medium"])

      vmaf = Repo.one(Vmaf)
      assert vmaf.video_id == video.id
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
      assert vmaf.size == "800 MB"
      assert vmaf.time == 120
      # ETA VMAF lines are marked as chosen
      assert vmaf.chosen == true
    end

    test "processes simple VMAF line without size information", %{video: video} do
      line =
        "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf 28 VMAF 91.33 (85%)"

      CrfSearch.process_line(line, video, ["--preset", "medium"])

      vmaf = Repo.one(Vmaf)
      assert vmaf.video_id == video.id
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
      # Sample VMAF lines are not marked as chosen
      assert vmaf.chosen == false
    end

    test "handles encoding sample line", %{video: video} do
      line = "encoding sample 2/5 crf 30"

      # This should not create a VMAF record, just process the line
      log =
        capture_log(fn ->
          CrfSearch.process_line(line, video, [])
        end)

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      # Should be processed successfully - no "No match for line" error should appear
      # However, the "Starting CRF search..." line might produce a "No match" warning
      # We should only check that the specific line we're testing doesn't produce an error
      refute log =~ "No match for line: encoding sample 2/5 crf 30"
    end

    test "handles progress line", %{video: video} do
      line = "[2024-12-12T00:13:08Z INFO] Progress: 45.2%, 15.3 fps, eta 2 minutes"

      log =
        capture_log(fn ->
          CrfSearch.process_line(line, video, [])
        end)

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      # Should be processed successfully
      refute log =~ "No match for line"
    end

    test "handles success line", %{video: video} do
      # First create a VMAF record that can be marked as chosen
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          params: ["--preset", "medium"]
        })

      line = "crf 28 successful"

      CrfSearch.process_line(line, video, [])

      # Should mark the VMAF as chosen
      vmaf = Repo.one(Vmaf)
      assert vmaf.chosen == true
    end
  end

  describe "error handling in line processing" do
    setup do
      video = video_fixture(%{path: "/test/error_video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "handles ab-av1 error line", %{video: video} do
      # Create a VMAF record first to test retry logic
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          params: ["--preset", "medium"]
        })

      line = "Error: Failed to find a suitable crf"

      log =
        capture_log(fn ->
          CrfSearch.process_line(line, video, [], 95)
        end)

      # Should process error and trigger retry logic
      assert log =~ "Failed to find a suitable CRF"
    end
  end

  # Helper functions
  defp sample_vmaf_line(opts) do
    crf = Keyword.get(opts, :crf, 28)
    score = Keyword.get(opts, :score, 91.33)
    percent = Keyword.get(opts, :percent, 85)

    "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf #{crf} VMAF #{score} (#{percent}%)"
  end
end
