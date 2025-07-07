defmodule Reencodarr.AbAv1.CrfSearchTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  describe "process_line/3 (direct call)" do
    setup do
      video = %{id: 1, path: "test_path", size: 100}
      {:ok, video} = Media.create_video(video)
      %{video: video}
    end

    test "creates VMAF record for valid line", %{video: video} do
      line =
        "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf 28 VMAF 91.33 (4%)"

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      CrfSearch.process_line(line, video, [])
      assert Repo.aggregate(Vmaf, :count, :id) == 1
      vmaf = Repo.one(Vmaf)
      assert vmaf.video_id == video.id
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
    end

    test "does not create VMAF record for invalid line", %{video: video} do
      line =
        "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] encoding sample 1/5 crf 28"

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      CrfSearch.process_line(line, video, [])
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "parses multiple lines from fixture file and creates VMAF records for valid lines", %{
      video: video
    } do
      lines =
        File.read!("test/fixtures/crf-search-output.txt")
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      assert Repo.aggregate(Vmaf, :count, :id) == 0

      Enum.each(lines, fn line ->
        CrfSearch.process_line(line, video, [])
      end)

      # The database uses upsert with conflict_target: [:crf, :video_id]
      # This means we get one record per unique CRF value for this video
      # Expected unique CRF values: 17.2, 19.3, 19.300001, 19.8, 19.800001,
      # 20.2, 20.5, 20.7, 20.8, 20.800001, 21.2, 22, 22.4, 22.7, 23.1, 28
      expected_count = 16
      actual_count = Repo.aggregate(Vmaf, :count, :id)

      msg =
        "Expected #{expected_count} VMAF records " <>
          "(one per unique CRF value), got #{actual_count}"

      assert actual_count == expected_count, msg
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
end
