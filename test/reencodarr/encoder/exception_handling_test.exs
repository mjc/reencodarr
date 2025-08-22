defmodule Reencodarr.Encoder.ExceptionHandlingTest do
  use Reencodarr.DataCase
  import ExUnit.CaptureLog

  alias Reencodarr.{FailureTracker, Media}
  alias Reencodarr.Media.VideoFailure

  describe "exception handling in encoding" do
    test "records detailed exception failure with full context" do
      video = Fixtures.video_fixture()

      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 95.0,
          params: ["--preset", "8"]
        })

      # Simulate an exception with full context
      exception_context = %{
        exception_type: "Elixir.File.Error",
        exception_message: "could not open file: no such file or directory",
        stacktrace: "test stacktrace",
        vmaf_id: vmaf.id,
        video_path: video.path,
        attempted_command: ["encode", "--crf", "28", video.path],
        command_line: "ab-av1 encode --crf 28 #{video.path}",
        exit_code: :exception,
        stage: "encoding_setup"
      }

      log =
        capture_log(fn ->
          {:ok, failure} = FailureTracker.record_exception_failure(video, exception_context)

          # Verify the failure was recorded with detailed context
          failure = Repo.get!(VideoFailure, failure.id)

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :process_failure
          assert failure.failure_code == "EXCEPTION"
          assert String.contains?(failure.failure_message, "Exception during encoding")
          assert String.contains?(failure.failure_message, "File.Error")
          assert String.contains?(failure.failure_message, "no such file or directory")

          # Verify full context is preserved
          assert failure.system_context["exception_type"] == "Elixir.File.Error"
          assert failure.system_context["stacktrace"] == "test stacktrace"
          assert failure.system_context["command_line"] == "ab-av1 encode --crf 28 #{video.path}"
          assert failure.system_context["stage"] == "encoding_setup"
          assert failure.system_context["error_type"] == "exception"

          # Video should be marked as failed
          updated_video = Repo.get!(Media.Video, video.id)
          assert updated_video.state == :failed
        end)

      assert log =~ "Recorded encoding/process_failure failure for video #{video.id}"
    end

    test "handles -3 exit code classification" do
      video = Fixtures.video_fixture()

      log =
        capture_log(fn ->
          {:ok, failure} =
            FailureTracker.record_process_failure(video, -3,
              context: %{
                original_exit_code: :exception,
                command: "ab-av1 encode test.mkv",
                full_output: "Exception occurred during setup"
              }
            )

          failure = Repo.get!(VideoFailure, failure.id)

          assert failure.failure_stage == :encoding
          assert failure.failure_category == :process_failure
          assert failure.failure_code == "EXIT_-3"
          assert String.contains?(failure.failure_message, "Exception during encoding setup")
        end)

      assert log =~ "Recorded encoding/process_failure failure for video #{video.id}"
    end

    test "captures context when exception occurs during command building" do
      video = Fixtures.video_fixture()

      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 95.0,
          params: ["--preset", "8"]
        })

      # Context when we can't even build the command
      fallback_context = %{
        exception_type: "Elixir.ArgumentError",
        exception_message: "invalid argument in command building",
        stacktrace: "command building stacktrace",
        vmaf_id: vmaf.id,
        video_path: video.path,
        # fallback command
        attempted_command: ["encode", "--crf", "28.0", video.path],
        command_line: "ab-av1 encode --crf 28.0 #{video.path}",
        exit_code: :exception,
        stage: "encoding_setup"
      }

      _log =
        capture_log(fn ->
          {:ok, failure} = FailureTracker.record_exception_failure(video, fallback_context)

          failure = Repo.get!(VideoFailure, failure.id)

          assert failure.system_context["attempted_command"] == [
                   "encode",
                   "--crf",
                   "28.0",
                   video.path
                 ]

          assert String.contains?(failure.system_context["command_line"], "ab-av1 encode")
        end)
    end
  end
end
