defmodule Reencodarr.AbAv1.ProgressParserTest do
  use Reencodarr.DataCase, async: true
  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.ProgressParser
  alias Reencodarr.Media

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
      line = "[2024-01-01T12:00:00Z] encoding #{state.video.id}.mkv"

      _log =
        capture_log(fn ->
          assert :ok = ProgressParser.process_line(line, state)
        end)

      # Should emit telemetry for encoding start
      # Note: Testing telemetry directly would require setting up handlers
      # For now, we verify the function completes without error
    end

    test "handles main progress pattern with full data", %{state: state} do
      line = "[2024-01-01T12:00:00Z] 45%, 23.5 fps, eta 120 minutes"

      # Mock telemetry to capture events
      test_pid = self()

      :telemetry.attach(
        "test-progress",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, measurements}
      assert measurements.percent == 45
      # parse_fps rounds 23.5 to 24.0
      assert measurements.fps == 24.0
      assert measurements.eta == "120 minutes"
      assert measurements.filename == "video.mkv"

      :telemetry.detach("test-progress")
    end

    test "handles alternative progress pattern without brackets", %{state: state} do
      line = "67%, 15.2 fps, eta 45 seconds"

      test_pid = self()

      :telemetry.attach(
        "test-alt-progress",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, measurements}
      assert measurements.percent == 67
      # parse_fps rounds to integer
      assert measurements.fps == 15.0
      assert measurements.eta == "45 seconds"

      :telemetry.detach("test-alt-progress")
    end

    test "handles file size progress pattern", %{state: state} do
      line = "Encoded 2.5 GB (75%)"

      # This pattern is currently ignored, but should not error
      assert :ok = ProgressParser.process_line(line, state)
    end

    test "handles FPS parsing with missing decimal point", %{state: state} do
      line = "50%, 30 fps, eta 90 minutes"

      test_pid = self()

      :telemetry.attach(
        "test-fps-int",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, measurements}
      assert measurements.fps == 30.0

      :telemetry.detach("test-fps-int")
    end

    test "handles different time units", %{state: state} do
      time_units = [
        {"10 seconds", "10 seconds"},
        {"5 minutes", "5 minutes"},
        {"2 hours", "2 hours"},
        {"1 days", "1 days"},
        {"3 weeks", "3 weeks"},
        {"1 months", "1 months"},
        {"1 years", "1 years"}
      ]

      Enum.each(time_units, fn {unit_input, expected_eta} ->
        line = "75%, 20.0 fps, eta #{unit_input}"

        test_pid = self()
        handler_id = "test-time-#{:rand.uniform(10000)}"

        :telemetry.attach(
          handler_id,
          [:reencodarr, :encoder, :progress],
          fn _event, measurements, _metadata, _config ->
            send(test_pid, {:telemetry_event, measurements})
          end,
          nil
        )

        assert :ok = ProgressParser.process_line(line, state)

        assert_receive {:telemetry_event, measurements}
        assert measurements.eta == expected_eta

        :telemetry.detach(handler_id)
      end)
    end

    test "logs warning for unmatched progress-like lines", %{state: state} do
      line = "Some line with 45% progress but wrong format"

      log =
        capture_log(fn ->
          assert :ok = ProgressParser.process_line(line, state)
        end)

      assert log =~ "ProgressParser: Unmatched encoding progress-like line"
      assert log =~ "Some line with 45% progress but wrong format"
    end

    test "ignores non-progress lines silently", %{state: state} do
      line = "Random log message without progress information"

      log =
        capture_log(fn ->
          assert :ok = ProgressParser.process_line(line, state)
        end)

      # Should not log anything specific to ProgressParser for non-progress lines
      # May contain unrelated logs from other processes, but should not contain ProgressParser warnings
      refute log =~ "ProgressParser:"
    end

    test "handles edge case with zero fps", %{state: state} do
      line = "25%, 0.0 fps, eta 999 hours"

      test_pid = self()

      :telemetry.attach(
        "test-zero-fps",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, measurements}
      assert measurements.fps == 0.0

      :telemetry.detach("test-zero-fps")
    end

    test "handles very high fps values", %{state: state} do
      line = "95%, 999.99 fps, eta 1 seconds"

      test_pid = self()

      :telemetry.attach(
        "test-high-fps",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, measurements}
      # parse_fps rounds 999.99 to 1000.0
      assert measurements.fps == 1000.0

      :telemetry.detach("test-high-fps")
    end

    test "handles complex video filenames correctly", %{state: state} do
      # Update the video in the database with the complex path
      {:ok, complex_video} =
        Media.update_video(state.video, %{
          path: "/tv/Breaking.Bad.S01E01.Pilot.1080p.BluRay.x264-ROVERS.mkv"
        })

      # Use the actual video ID from the created video
      line = "[2024-01-01T12:00:00Z] encoding #{complex_video.id}.mkv"

      test_pid = self()

      :telemetry.attach(
        "test-complex-filename",
        [:reencodarr, :encoder, :started],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, metadata})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, metadata}
      assert metadata.filename == "Breaking.Bad.S01E01.Pilot.1080p.BluRay.x264-ROVERS.mkv"

      :telemetry.detach("test-complex-filename")
    end
  end

  describe "parse_fps/1 (private function testing via public interface)" do
    setup do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/fps_test.mkv",
          service_id: "test",
          service_type: :sonarr,
          size: 1_000_000_000
        })

      state = %{
        video: video,
        vmaf: %{id: 2, video: video},
        output_file: "/tmp/2.mkv",
        port: :test_port,
        partial_line_buffer: ""
      }

      %{state: state}
    end

    test "parses integer fps correctly", %{state: state} do
      line = "50%, 25 fps, eta 60 minutes"

      test_pid = self()

      :telemetry.attach(
        "test-int-fps",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, measurements}
      assert measurements.fps == 25.0

      :telemetry.detach("test-int-fps")
    end

    test "parses decimal fps correctly", %{state: state} do
      line = "50%, 23.75 fps, eta 60 minutes"

      test_pid = self()

      :telemetry.attach(
        "test-decimal-fps",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_event, measurements}
      # parse_fps rounds 23.75 to 24.0
      assert measurements.fps == 24.0

      :telemetry.detach("test-decimal-fps")
    end
  end
end
