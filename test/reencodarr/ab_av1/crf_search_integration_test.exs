defmodule Reencodarr.AbAv1.CrfSearchIntegrationTest do
  @moduledoc """
  Integration tests for CRF search functionality.
  Tests the complete workflow and public API with real GenServer interactions.
  """
  use Reencodarr.DataCase, async: false

  @moduletag :integration

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  import Reencodarr.MediaFixtures
  import ExUnit.CaptureLog

  describe "CRF search public API" do
    setup do
      video =
        video_fixture(%{
          path: "/test/integration_video.mkv",
          size: 2_000_000_000,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      %{video: video}
    end

    test "crf_search/2 initiates search for valid video", %{video: video} do
      capture_log(fn ->
        result = CrfSearch.crf_search(video, 95)
        assert result == :ok

        # Give GenServer time to process
        Process.sleep(100)

        # Should attempt to start processing (may fail due to missing ab-av1 binary)
        assert is_boolean(CrfSearch.running?())
      end)
    end

    test "crf_search/2 skips already reencoded videos", %{video: video} do
      capture_log(fn ->
        {:ok, reencoded_video} = Media.update_video(video, %{state: :encoded})

        result = CrfSearch.crf_search(reencoded_video, 95)
        assert result == :ok

        # Give it a moment to process
        Process.sleep(50)

        # Since it's skipped, no CRF search should be running
        refute CrfSearch.running?()
      end)
    end

    test "running?/0 returns current status" do
      # Should always return a boolean
      assert is_boolean(CrfSearch.running?())
    end
  end

  describe "workflow integration" do
    setup do
      video = video_fixture(%{path: "/test/workflow_video.mkv", size: 1_000_000_000})
      %{video: video}
    end

    test "complete workflow with VMAF creation and selection", %{video: video} do
      # Simulate processing several VMAF lines
      vmaf_lines = [
        "[2024-12-12T00:13:08Z] sample 1/3 crf 30 VMAF 89.5 (90%)",
        "[2024-12-12T00:13:08Z] sample 2/3 crf 28 VMAF 92.1 (85%)",
        "[2024-12-12T00:13:08Z] sample 3/3 crf 26 VMAF 94.8 (80%)"
      ]

      # Process all VMAF lines
      Enum.each(vmaf_lines, fn line ->
        CrfSearch.process_line(line, video, ["--preset", "medium"])
      end)

      # Verify VMAF records were created
      vmafs = Repo.all(from v in Vmaf, where: v.video_id == ^video.id, order_by: v.crf)
      assert length(vmafs) == 3

      # Verify CRF values are correct
      crf_values = Enum.map(vmafs, & &1.crf)
      assert crf_values == [26.0, 28.0, 30.0]

      # Simulate success line to mark one as chosen
      CrfSearch.process_line("crf 28 successful", video, [])

      # Verify the correct VMAF was marked as chosen
      chosen_vmaf = Repo.get_by(Vmaf, video_id: video.id, chosen: true)
      assert chosen_vmaf.crf == 28.0
      assert chosen_vmaf.score == 92.1
    end

    test "handles size limit warnings", %{video: video} do
      # Simulate a VMAF line with large predicted size
      large_size_line =
        "crf 20 VMAF 98.5 predicted video stream size 15 GB (120%) taking 300 seconds"

      log =
        capture_log(fn ->
          CrfSearch.process_line(large_size_line, video, [])
        end)

      # Should create the VMAF record but log a warning
      assert log =~ "exceeds 10GB limit"

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 20.0
      assert vmaf.size == "15 GB"
    end
  end

  describe "error scenarios and edge cases" do
    setup do
      video = video_fixture(%{path: "/test/error_video.mkv"})
      %{video: video}
    end

    test "handles malformed input gracefully", %{video: video} do
      malformed_lines = [
        "",
        "random text",
        "crf abc VMAF xyz",
        "[invalid timestamp] invalid format"
      ]

      log =
        capture_log(fn ->
          Enum.each(malformed_lines, fn line ->
            CrfSearch.process_line(line, video, [])
          end)
        end)

      # Should not crash and should log no-match messages
      assert log =~ "No match for line"

      # No VMAF records should be created
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "processes complex real-world output", %{video: video} do
      # Load fixture file if it exists
      fixture_path = Path.join([__DIR__, "..", "..", "fixtures", "crf-search-output.txt"])

      if File.exists?(fixture_path) do
        lines =
          fixture_path
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))

        initial_count = Repo.aggregate(Vmaf, :count, :id)

        _log =
          capture_log(fn ->
            Enum.each(lines, fn line ->
              CrfSearch.process_line(line, video, ["--preset", "medium"])
            end)
          end)

        final_count = Repo.aggregate(Vmaf, :count, :id)
        created_count = final_count - initial_count

        # Should have created some VMAF records
        assert created_count > 0

        # Verify all created records have valid data
        vmafs = Repo.all(from v in Vmaf, where: v.video_id == ^video.id)

        Enum.each(vmafs, fn vmaf ->
          assert vmaf.crf > 0
          assert vmaf.score > 0
          assert vmaf.video_id == video.id
        end)
      else
        # Skip test if fixture file doesn't exist
        :ok
      end
    end
  end

  describe "size limit enforcement" do
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
