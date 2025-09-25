defmodule Reencodarr.AbAv1.ProgressParserTest do
  use Reencodarr.DataCase, async: true
  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.ProgressParser

  describe "process_line/2" do
    setup do
      # Create a test video using the factory
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/unique_#{System.unique_integer([:positive])}/video.mkv",
          service_id: "test",
          service_type: :sonarr,
          size: 1_000_000_000
        })

      state = %{
        video: video,
        vmaf: %{id: 1, video: video},
        output_file: "/tmp/1.mkv",
        port: :test_port,
        partial_line_buffer: ""
      }

      %{video: video, state: state}
    end

    test "handles encoding start line", %{state: state} do
      line = "Encoding video.mkv ..."
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles main progress pattern with full data", %{state: state} do
      line = "[2024-01-01T12:00:00Z] 45%, 23.5 fps, eta 120 minutes"
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles alternative progress pattern without brackets", %{state: state} do
      line = "67%, 15.2 fps, eta 45 seconds"
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles file size progress pattern", %{state: state} do
      line = "Encoded 2.5 GB (75%)"
      # This pattern is currently ignored, but should not error
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles FPS parsing with missing decimal point", %{state: state} do
      line = "50%, 30 fps, eta 90 minutes"
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles different time units", %{state: state} do
      time_units = [
        "10 seconds",
        "5 minutes",
        "2 hours",
        "1 days",
        "3 weeks",
        "1 months",
        "1 years"
      ]

      Enum.each(time_units, fn unit_input ->
        line = "75%, 20.0 fps, eta #{unit_input}"
        assert :ok = ProgressParser.process_line(line, state)
      end)
    end

    test "logs warning for unmatched progress-like lines", %{state: state} do
      line = "Some line with 45% progress but wrong format"

      log =
        capture_log(fn ->
          assert :ok = ProgressParser.process_line(line, state)
        end)

      assert log =~ "Unmatched encoding progress-like line"
    end

    test "handles edge case with zero fps", %{state: state} do
      line = "25%, 0.0 fps, eta Unknown"
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles very high fps values", %{state: state} do
      line = "99%, 999.9 fps, eta 1 seconds"
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles complex video filenames correctly", %{state: state} do
      # Test with a complex filename that might confuse the parser
      complex_state = %{
        state
        | video: %{state.video | path: "/test/Weird Movie [2024] S01E01.mkv"}
      }

      line = "Encoding Weird Movie [2024] S01E01.mkv ..."
      assert :ok = ProgressParser.process_line(line, complex_state)
    end

    test "ignores lines that don't match any patterns", %{state: state} do
      line = "Some random log line without progress indicators"
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles empty string gracefully", %{state: state} do
      assert :ok = ProgressParser.process_line("", state)
    end

    test "handles whitespace-only lines gracefully", %{state: state} do
      assert :ok = ProgressParser.process_line("   \t  \n  ", state)
    end

    test "handles state without video", %{state: state} do
      line = "50%, 25 fps, eta 10 minutes"
      state_without_video = %{state | video: nil}
      assert :ok = ProgressParser.process_line(line, state_without_video)
    end
  end
end
