defmodule Reencodarr.FailureTracker.CommandOutputTest do
  use Reencodarr.DataCase
  import ExUnit.CaptureLog

  alias Reencodarr.FailureTracker

  describe "enhanced command output capture" do
    test "build_command_context creates proper context from args and output" do
      args = ["crf-search", "--vmaf", "95", "/path/to/video.mkv"]
      output_lines = ["Sample line 1", "Sample line 2", "Error: Failed to find suitable crf"]
      extra_context = %{target_vmaf: 95.0, video_id: 123}

      context = FailureTracker.build_command_context(args, output_lines, extra_context)

      assert context.command == "ab-av1 crf-search --vmaf 95 /path/to/video.mkv"
      assert context.args == args

      assert context.full_output ==
               "Sample line 1\nSample line 2\nError: Failed to find suitable crf"

      assert context.target_vmaf == 95.0
      assert context.video_id == 123
    end

    test "build_command_context handles string output" do
      args = ["encode", "-c", "23", "input.mkv", "output.mkv"]
      output = "Progress: 50%\nError: Encoding failed"

      context = FailureTracker.build_command_context(args, output)

      assert context.command == "ab-av1 encode -c 23 input.mkv output.mkv"
      assert context.full_output == "Progress: 50%\nError: Encoding failed"
    end

    test "process failure with enhanced context includes command output" do
      {:ok, video} = Fixtures.video_fixture()

      # Simulate ab-av1 command output
      args = ["encode", "-c", "25", "--preset", "4", video.path, "output.mkv"]

      output_lines = [
        "ab-av1 0.7.15",
        "Encoding with CRF 25",
        "Progress: 25%",
        "Progress: 50%",
        "Error: Out of memory",
        "Process terminated"
      ]

      enhanced_context =
        FailureTracker.build_command_context(args, output_lines, %{
          target_vmaf: 95.0,
          video_duration: 7200,
          encoding_preset: 4
        })

      log =
        capture_log(fn ->
          {:ok, failure} =
            FailureTracker.record_process_failure(video, 137, context: enhanced_context)

          # Verify the failure was recorded with full context
          failure = Reencodarr.Repo.get!(Reencodarr.Media.VideoFailure, failure.id)

          assert failure.failure_code == "EXIT_137"

          assert failure.system_context["command"] ==
                   "ab-av1 encode -c 25 --preset 4 #{video.path} output.mkv"

          assert failure.system_context["args"] == args
          assert String.contains?(failure.system_context["full_output"], "Error: Out of memory")
          assert String.contains?(failure.system_context["full_output"], "Progress: 50%")
          assert failure.system_context["target_vmaf"] == 95.0
          assert failure.system_context["encoding_preset"] == 4
        end)

      # Verify log message was captured
      assert log =~ "Recorded encoding/resource_exhaustion failure for video #{video.id}"
      assert log =~ "Process killed by system (likely OOM)"
    end

    test "crf search failure with command context" do
      {:ok, video} = Fixtures.video_fixture()

      # Simulate ab-av1 crf-search output
      args = ["crf-search", "--vmaf", "95", "--min-crf", "20", "--max-crf", "30", video.path]

      output_lines = [
        "ab-av1 0.7.15",
        "Testing CRF 25 for target VMAF 95.0",
        "Sample 1/3 CRF 25 VMAF 94.2 (33%)",
        "Sample 2/3 CRF 23 VMAF 96.1 (66%)",
        "Sample 3/3 CRF 24 VMAF 95.8 (100%)",
        "Error: Failed to find a suitable crf"
      ]

      enhanced_context =
        FailureTracker.build_command_context(args, output_lines, %{
          target_vmaf: 95.0,
          tested_scores: [
            %{crf: 25, score: 94.2},
            %{crf: 23, score: 96.1},
            %{crf: 24, score: 95.8}
          ]
        })

      log =
        capture_log(fn ->
          {:ok, failure} =
            FailureTracker.record_crf_optimization_failure(video, 95.0, [],
              context: enhanced_context
            )

          # Verify comprehensive failure context
          failure = Reencodarr.Repo.get!(Reencodarr.Media.VideoFailure, failure.id)

          assert failure.failure_category == :crf_optimization
          assert failure.failure_code == "CRF_NOT_FOUND"

          assert failure.system_context["command"] ==
                   "ab-av1 crf-search --vmaf 95 --min-crf 20 --max-crf 30 #{video.path}"

          assert String.contains?(
                   failure.system_context["full_output"],
                   "Error: Failed to find a suitable crf"
                 )

          assert String.contains?(
                   failure.system_context["full_output"],
                   "Sample 2/3 CRF 23 VMAF 96.1"
                 )

          assert failure.system_context["target_vmaf"] == 95.0
          assert is_list(failure.system_context["tested_scores"])
        end)

      # Verify log message was captured
      assert log =~ "Recorded crf_search/crf_optimization failure for video #{video.id}"
      assert log =~ "Failed to find suitable CRF for target VMAF 95.0"
    end

    test "vmaf calculation failure with full ab-av1 output" do
      {:ok, video} = Fixtures.video_fixture()

      args = ["crf-search", "--vmaf", "95", video.path]

      output_lines = [
        "ab-av1 0.7.15",
        "Starting CRF search for target VMAF 95.0",
        "ffmpeg -i #{video.path} -t 30 -f yuv4mpegpipe",
        "SvtAv1EncApp --preset 4 --crf 25",
        "vmaf version 2.3.1",
        "Computing VMAF score...",
        "Error: VMAF calculation failed",
        "vmaf: Segmentation fault (core dumped)"
      ]

      enhanced_context =
        FailureTracker.build_command_context(args, output_lines, %{
          target_vmaf: 95.0,
          preset: 4,
          error_type: "segfault"
        })

      log =
        capture_log(fn ->
          {:ok, failure} =
            FailureTracker.record_vmaf_calculation_failure(video, "VMAF process crashed",
              context: enhanced_context
            )

          # Verify crash details are captured
          failure = Reencodarr.Repo.get!(Reencodarr.Media.VideoFailure, failure.id)

          assert failure.failure_category == :vmaf_calculation
          assert failure.failure_code == "VMAF_CALC"

          assert String.contains?(
                   failure.system_context["full_output"],
                   "vmaf: Segmentation fault"
                 )

          assert String.contains?(
                   failure.system_context["full_output"],
                   "Computing VMAF score..."
                 )

          assert failure.system_context["error_type"] == "segfault"
          assert failure.system_context["preset"] == 4
        end)

      # Verify log message was captured
      assert log =~ "Recorded crf_search/vmaf_calculation failure for video #{video.id}"
      assert log =~ "VMAF calculation failed: VMAF process crashed"
    end

    test "crf optimization failure with vmaf scores uses maps not tuples" do
      {:ok, video} = Fixtures.video_fixture()

      # Create some VMAF records for this video to simulate real scenario
      {:ok, _vmaf1} =
        Reencodarr.Media.create_vmaf(%{
          video_id: video.id,
          crf: 10.0,
          score: 48.49,
          params: ["--preset", "4"],
          predicted_filesize: 1_000_000,
          predicted_bitrate: 5000
        })

      {:ok, _vmaf2} =
        Reencodarr.Media.create_vmaf(%{
          video_id: video.id,
          crf: 15.0,
          score: 52.3,
          params: ["--preset", "4"],
          predicted_filesize: 800_000,
          predicted_bitrate: 4000
        })

      log =
        capture_log(fn ->
          # This should not cause a JSON encoding error
          {:ok, failure} = FailureTracker.record_crf_optimization_failure(video, 95.0, [])

          failure = Reencodarr.Repo.get!(Reencodarr.Media.VideoFailure, failure.id)

          # Verify the tested_scores are stored as maps, not tuples
          assert is_list(failure.system_context["tested_scores"])

          if not Enum.empty?(failure.system_context["tested_scores"]) do
            first_score = List.first(failure.system_context["tested_scores"])
            assert is_map(first_score)
            assert Map.has_key?(first_score, "crf")
            assert Map.has_key?(first_score, "score")
          end
        end)

      # Verify log message was captured
      assert log =~ "Recorded crf_search/crf_optimization failure for video #{video.id}"
      assert log =~ "Failed to find suitable CRF for target VMAF 95.0"
    end
  end
end
