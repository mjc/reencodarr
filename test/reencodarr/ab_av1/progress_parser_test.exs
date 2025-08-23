defmodule Reencodarr.AbAv1.ProgressParserTest do
  use Reencodarr.DataCase, async: true
  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.ProgressParser
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  describe "process_line/2" do
    setup do
      # Create a test video using the factory
      video =
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
      assert measurements.fps == 23.5
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
      assert measurements.fps == 15.2
      assert measurements.eta == "45 seconds"

      :telemetry.detach("test-alt-progress")
    end

    test "handles file size progress pattern", %{state: state} do
      line = "Encoded 2.5 GB (75%)"

      test_pid = self()

      :telemetry.attach(
        "test-file-progress",
        [:reencodarr, :encoder, :progress],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_received, measurements})
        end,
        nil
      )

      assert :ok = ProgressParser.process_line(line, state)

      assert_receive {:telemetry_received, measurements}
      assert measurements.percent == 75
      assert measurements.size == 2.5
      assert measurements.size_unit == "GB"
      assert measurements.fps == 0.0
      assert measurements.eta == "unknown"

      :telemetry.detach("test-file-progress")
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
      assert measurements.fps == 999.99

      :telemetry.detach("test-high-fps")
    end

    test "handles complex video filenames correctly", %{state: state} do
      # Update the video in the database with the complex path
      {:ok, complex_video} =
        Media.update_video(state.video, %{
          path: "/tv/Breaking.Bad.S01E01.Pilot.1080p.BluRay.x264-ROVERS.mkv"
        })

      # Update the state to use the complex video
      updated_state = %{state | video: complex_video}

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

      assert :ok = ProgressParser.process_line(line, updated_state)

      assert_receive {:telemetry_event, metadata}
      assert metadata.filename == "Breaking.Bad.S01E01.Pilot.1080p.BluRay.x264-ROVERS.mkv"

      :telemetry.detach("test-complex-filename")
    end
  end

  describe "parse_fps/1 (private function testing via public interface)" do
    setup do
      video =
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
      assert measurements.fps == 23.75

      :telemetry.detach("test-decimal-fps")
    end
  end

  # =============================================================================
  # CRF Search Pattern Matching Tests
  # =============================================================================

  describe "CRF search pattern matching" do
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
        Path.join([__DIR__, "..", "..", "fixtures", "crf-search-output.txt"])
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      encoding_lines =
        Path.join([__DIR__, "..", "..", "fixtures", "encoding-output.txt"])
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      %{video: video, crf_search_lines: crf_search_lines, encoding_lines: encoding_lines}
    end

    test "matches simple VMAF pattern", %{video: video, crf_search_lines: lines} do
      # Use the first sample VMAF line from fixture
      line = Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 28 VMAF 91.33"))

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      ProgressParser.process_line(line, {video, [], 95})
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

      ProgressParser.process_line(line, {video, [], 95})

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 90.52
      assert vmaf.percent == 3.0
    end

    test "matches simple VMAF without percentage", %{video: video, crf_search_lines: lines} do
      # Use dash pattern line from fixture
      line = Enum.find(lines, &String.contains?(&1, "- crf 28 VMAF 90.52"))

      ProgressParser.process_line(line, {video, [], 95})

      vmaf = Repo.one(Vmaf)
      assert vmaf.crf == 28.0
      assert vmaf.score == 90.52
      assert vmaf.percent == 3.0
    end

    test "matches success pattern and marks chosen VMAF", %{video: video, crf_search_lines: lines} do
      # First add a VMAF record using the crf line from fixture
      crf_line =
        "crf 23.1 VMAF 95.14 predicted video stream size 439.91 MiB (4%) taking 31 minutes"

      ProgressParser.process_line(crf_line, {video, [], 95})

      # Then process success line from fixture
      success_line = Enum.find(lines, &String.contains?(&1, "crf 23.1 successful"))

      ProgressParser.process_line(success_line, {video, [], 95})

      # Should update the VMAF as chosen
      vmaf = Repo.one(Vmaf)
      assert vmaf.chosen == true
      assert vmaf.crf == 23.1
    end

    test "handles warning patterns", %{video: video} do
      warning_lines = [
        "Warning: you may want to set a max-crf to prevent really low quality encodes",
        "Warning: target VMAF (95) not reached for any CRF"
      ]

      Enum.each(warning_lines, fn line ->
        log =
          capture_log(fn ->
            ProgressParser.process_line(line, {video, [], 95})
          end)

        # Warning lines should be handled properly and not generate "No match" errors
        refute log =~ "No match for line"
      end)
    end

    test "handles malformed but parseable lines", %{video: video} do
      # Use a line that matches the simple_vmaf pattern which expects a timestamp
      slightly_malformed_line = "[2024-12-12T00:13:08Z INFO] crf 22 VMAF 94.50 (75%)"

      ProgressParser.process_line(slightly_malformed_line, {video, [], 95})

      # Should create one VMAF record
      vmafs = Repo.all(Vmaf)
      assert length(vmafs) == 1
      vmaf = hd(vmafs)
      assert vmaf.crf == 22.0
      assert vmaf.score == 94.50
      assert vmaf.percent == 75.0
    end
  end

  # =============================================================================
  # CRF Search Line Processing Tests
  # =============================================================================

  describe "CRF search line processing" do
    setup do
      {:ok, video} =
        Media.create_video(%{
          path: "/test/video.mkv",
          size: 2_000_000_000,
          service_id: "23",
          service_type: :sonarr
        })

      %{video: video}
    end

    test "processes simple VMAF line", %{video: video} do
      line = "sample 1/5 crf 28 VMAF 91.33 (85%)"

      _log =
        capture_log(fn ->
          ProgressParser.process_line(line, {video, [], 95})
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
          ProgressParser.process_line(line, {video, [], 95})
        end)

      # With OutputParser, invalid lines now return :ignore and don't generate logs
      refute log =~ "error"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "processes VMAF line with size and time information", %{video: video} do
      line = "crf 28 VMAF 91.33 predicted video stream size 800 MB (85%) taking 120 seconds"

      ProgressParser.process_line(line, {video, ["--preset", "medium"], 95})

      vmaf = Repo.one(Vmaf)
      assert vmaf.video_id == video.id
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
      assert vmaf.size == "800.0 MB"
      assert vmaf.time == 120
      # ETA VMAF lines are marked as chosen
      assert vmaf.chosen == true
    end

    test "processes simple VMAF line without size information", %{video: video} do
      line =
        "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf 28 VMAF 91.33 (85%)"

      ProgressParser.process_line(line, {video, ["--preset", "medium"], 95})

      vmaf = Repo.one(Vmaf)
      assert vmaf.video_id == video.id
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
      assert vmaf.percent == 85.0
      refute vmaf.chosen
    end

    test "handles progress line", %{video: video} do
      line = "[2024-12-12T00:13:08Z INFO] Progress: 45.2%, 15.3 fps, eta 2 minutes"

      log =
        capture_log(fn ->
          ProgressParser.process_line(line, {video, [], 95})
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

      ProgressParser.process_line(line, {video, [], 95})

      vmaf = Repo.one(Vmaf)
      assert vmaf.chosen == true
    end
  end
end
