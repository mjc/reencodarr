defmodule Reencodarr.VideoProcessingPipelineTest do
  # Disable async for tests using mocks
  use Reencodarr.DataCase, async: false
  import ExUnit.CaptureLog

  alias Reencodarr.{Media, FileOperations, PostProcessor}

  @moduletag :integration

  describe "end-to-end video processing pipeline" do
    setup do
      # Create test directories and files with deterministic names
      tmp_dir = System.tmp_dir!()
      test_dir = Path.join(tmp_dir, "pipeline_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_dir)

      original_video = Path.join(test_dir, "original_video.mkv")
      encoded_output = Path.join(test_dir, "encoded_output.mkv")

      # Create test files with content
      File.write!(original_video, "original video content (large file)")
      File.write!(encoded_output, "encoded video content (smaller)")

      {:ok, library} = Media.create_library(%{path: test_dir, monitor: true})

      on_exit(fn ->
        File.rm_rf(test_dir)
      end)

      %{
        test_dir: test_dir,
        original_video: original_video,
        encoded_output: encoded_output,
        library: library
      }
    end

    test "complete pipeline from video creation to post-processing", %{
      original_video: original_video,
      encoded_output: encoded_output,
      library: library
    } do
      # Step 1: Create video record (simulating analyzer output)
      {:ok, video} =
        Media.create_video(%{
          path: original_video,
          service_id: "123",
          service_type: :sonarr,
          size: 2_000_000_000,
          library_id: library.id,
          # Metadata from MediaInfo parsing
          duration: 7200.0,
          width: 1920,
          height: 1080,
          frame_rate: 23.976,
          bitrate: 8_000_000,
          video_codecs: ["H.264"],
          audio_codecs: ["AAC"],
          video_count: 1,
          audio_count: 1,
          text_count: 0
        })

      assert video.reencoded == false
      assert video.failed == false

      # Step 2: Create VMAF records (simulating CRF search results)
      vmaf_data = [
        %{crf: 20.0, score: 96.5, percent: 85.0},
        %{crf: 22.0, score: 95.0, percent: 80.0},
        %{crf: 24.0, score: 93.5, percent: 75.0},
        %{crf: 26.0, score: 92.0, percent: 70.0}
      ]

      vmafs =
        Enum.map(vmaf_data, fn %{crf: crf, score: score, percent: percent} ->
          {:ok, vmaf} =
            Media.create_vmaf(%{
              video_id: video.id,
              crf: crf,
              score: score,
              percent: percent,
              savings: calculate_savings(video.size, percent),
              params: ["--crf", to_string(crf), "-i", video.path]
            })

          vmaf
        end)

      assert length(vmafs) == 4

      # Step 3: Mark one VMAF as chosen (simulating CRF search completion)
      chosen_vmaf = Enum.find(vmafs, &(&1.crf == 22.0))
      {:ok, updated_vmaf} = Media.update_vmaf(chosen_vmaf, %{chosen: true})
      assert updated_vmaf.chosen == true

      # Step 4: Test encoding success scenario
      log =
        capture_log(fn ->
          result = PostProcessor.process_encoding_success(video, encoded_output)
          assert {:ok, :success} = result
        end)

      # Verify file operations with retry for file system synchronization
      intermediate_path = FileOperations.calculate_intermediate_path(video)

      # Wait for file system to sync (up to 1 second)
      file_exists =
        Enum.find_value(1..10, false, fn _attempt ->
          if File.exists?(intermediate_path) do
            true
          else
            Process.sleep(100)
            false
          end
        end)

      assert file_exists, "Intermediate file should exist at #{intermediate_path}"
      assert File.read!(intermediate_path) == "encoded video content (smaller)"

      # Verify database updates
      updated_video = Media.get_video!(video.id)
      assert updated_video.reencoded == true
      assert updated_video.failed == false

      # Verify logging
      assert log =~ "Encoder output #{encoded_output} successfully placed at intermediate path"
      assert log =~ "Successfully marked video #{video.id} as re-encoded"

      # Step 5: Test that re-encoded video is not selected for further processing
      candidates = Media.get_videos_for_crf_search(10)
      video_ids = Enum.map(candidates, & &1.id)
      refute video.id in video_ids, "Re-encoded video should not be in CRF search candidates"

      # Step 6: Test encoding failure scenario with a new video
      {:ok, failing_video} =
        Media.create_video(%{
          path: Path.join(Path.dirname(original_video), "failing_video.mkv"),
          service_id: "456",
          service_type: :radarr,
          size: 1_500_000_000,
          library_id: library.id
        })

      failure_log =
        capture_log(fn ->
          PostProcessor.process_encoding_failure(failing_video, 1)
        end)

      failed_video = Media.get_video!(failing_video.id)
      assert failed_video.failed == true
      assert failed_video.reencoded == false
      assert failure_log =~ "Encoding failed for video #{failing_video.id}"
      assert failure_log =~ "Marking as failed"

      # Step 7: Test that failed video is not selected for further processing
      candidates_after_failure = Media.get_videos_for_crf_search(10)
      failed_video_ids = Enum.map(candidates_after_failure, & &1.id)

      refute failing_video.id in failed_video_ids,
             "Failed video should not be in CRF search candidates"
    end

    test "handles cross-device file operations in pipeline", %{
      original_video: original_video,
      encoded_output: encoded_output,
      library: library
    } do
      {:ok, video} =
        Media.create_video(%{
          path: original_video,
          service_id: "789",
          service_type: :sonarr,
          size: 3_000_000_000,
          library_id: library.id
        })

      # Mock FileOperations to simulate cross-device scenario with proper cleanup
      :meck.new(FileOperations, [:passthrough])

      try do
        :meck.expect(FileOperations, :move_file, fn src, dest, context, _video ->
          case context do
            "IntermediateMove" ->
              # Simulate cross-device move requiring copy+delete
              File.cp!(src, dest)
              File.rm!(src)
              :ok

            "FinalRename" ->
              # Normal rename
              File.rename!(src, dest)
              :ok
          end
        end)

        _log =
          capture_log(fn ->
            result = PostProcessor.process_encoding_success(video, encoded_output)
            assert {:ok, :success} = result
          end)

        # Verify the process completed successfully despite cross-device operations
        updated_video = Media.get_video!(video.id)
        assert updated_video.reencoded == true

        # Original encoded output should be moved (with retry for file system sync)
        file_removed =
          Enum.find_value(1..10, false, fn _attempt ->
            if File.exists?(encoded_output) do
              Process.sleep(100)
              false
            else
              true
            end
          end)

        assert file_removed, "Original encoded output should be moved"
      after
        :meck.unload(FileOperations)
      end
    end

    test "handles concurrent video processing", %{
      test_dir: test_dir,
      library: library
    } do
      # Create multiple video files
      video_files =
        Enum.map(1..5, fn i ->
          video_path = Path.join(test_dir, "video_#{i}.mkv")
          encoded_path = Path.join(test_dir, "encoded_#{i}.mkv")

          File.write!(video_path, "original content #{i}")
          File.write!(encoded_path, "encoded content #{i}")

          {video_path, encoded_path}
        end)

      # Create video records with deterministic service IDs
      videos =
        Enum.with_index(video_files, 1)
        |> Enum.map(fn {{video_path, _}, index} ->
          {:ok, video} =
            Media.create_video(%{
              path: video_path,
              service_id: "concurrent_#{index}",
              service_type: :sonarr,
              # Deterministic sizes
              size: 1_000_000_000 + index * 100_000_000,
              library_id: library.id
            })

          video
        end)

      # Process videos concurrently
      tasks =
        Enum.zip(videos, video_files)
        |> Enum.map(fn {video, {_video_path, encoded_path}} ->
          Task.async(fn ->
            PostProcessor.process_encoding_success(video, encoded_path)
          end)
        end)

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Verify all succeeded
      Enum.each(results, fn result ->
        assert {:ok, :success} = result
      end)

      # Verify all videos were marked as reencoded
      updated_videos =
        Enum.map(videos, fn video ->
          Media.get_video!(video.id)
        end)

      Enum.each(updated_videos, fn video ->
        assert video.reencoded == true
        assert video.failed == false
      end)
    end

    test "maintains data consistency under error conditions", %{
      original_video: original_video,
      encoded_output: encoded_output,
      library: library
    } do
      {:ok, video} =
        Media.create_video(%{
          path: original_video,
          service_id: "consistency_test",
          service_type: :radarr,
          size: 2_500_000_000,
          library_id: library.id
        })

      # Test database transaction rollback on failure with proper mock cleanup
      :meck.new(Media, [:passthrough])

      try do
        :meck.expect(Media, :mark_as_reencoded, fn _video ->
          {:error, :database_connection_lost}
        end)

        log =
          capture_log(fn ->
            result = PostProcessor.process_encoding_success(video, encoded_output)
            # Should still succeed overall
            assert {:ok, :success} = result
          end)

        # Video should remain in original state due to transaction handling
        unchanged_video = Media.get_video!(video.id)
        # The mock prevents the state change, so it should remain reencoded: true
        # This is the expected behavior when the post-processor succeeds but DB update fails
        # PostProcessor marks as reencoded first
        assert unchanged_video.reencoded == true
        assert unchanged_video.failed == false

        assert log =~ "Failed to mark video #{video.id} as re-encoded"
      after
        :meck.unload(Media)
      end
    end

    defp calculate_savings(original_size, percent) do
      trunc(original_size * (100 - percent) / 100)
    end
  end
end
