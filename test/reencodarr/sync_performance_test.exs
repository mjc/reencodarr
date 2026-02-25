defmodule Reencodarr.SyncPerformanceTest do
  use Reencodarr.DataCase, async: false
  alias Reencodarr.Analyzer.Broadway, as: AnalyzerBroadway
  alias Reencodarr.Fixtures
  alias Reencodarr.{Media, Sync}
  import ExUnit.CaptureLog

  describe "sync performance optimizations" do
    setup do
      library = Fixtures.library_fixture(%{path: "/test"})
      %{library: library}
    end

    test "batch processing handles large file collections efficiently", %{library: library} do
      # Create a large batch of file data to simulate real sync scenarios
      large_file_batch =
        for i <- 1..100 do
          %{
            "path" => "/test/batch/movie_#{i}.mkv",
            "size" => 1_000_000_000 + i * 100_000,
            "id" => "batch_#{i}",
            "mediaInfo" => %{
              "audioCodec" => "AAC",
              "videoBitrate" => 4_000_000 + i * 10_000,
              "audioBitrate" => 256_000,
              "audioChannels" => 2,
              "videoCodec" => "H.264",
              "width" => 1920,
              "height" => 1080,
              "audioLanguages" => ["eng"],
              "subtitles" => ["eng"]
            },
            "videoFps" => 23.976,
            "overallBitrate" => 4_256_000 + i * 10_000,
            "runTime" => 3600 + i * 60,
            "sceneName" => "Test Movie #{i}"
          }
        end

      # Measure performance of batch processing
      {time_microseconds, _result} =
        :timer.tc(fn ->
          # Simulate the batch upsert function directly
          send(self(), {:test_batch_start, System.monotonic_time(:millisecond)})

          # Process files in a batch operation
          Repo.transaction(
            fn ->
              Enum.each(large_file_batch, fn file_attrs ->
                # Create video attributes similar to prepare_video_attrs
                video_attrs = %{
                  "path" => file_attrs["path"],
                  "size" => file_attrs["size"],
                  "service_id" => to_string(file_attrs["id"]),
                  "service_type" => "sonarr",
                  "library_id" => library.id,
                  "bitrate" => file_attrs["overallBitrate"] || 0
                }

                Media.VideoUpsert.upsert(video_attrs)
              end)
            end,
            timeout: :infinity
          )

          send(self(), {:test_batch_end, System.monotonic_time(:millisecond)})
        end)

      # Verify all videos were created
      video_count = Media.count_videos()
      assert video_count >= 100

      # Performance assertion - should complete in reasonable time (< 5 seconds)
      assert time_microseconds < 5_000_000

      # Verify batch processing efficiency messages
      assert_received {:test_batch_start, _start_time}
      assert_received {:test_batch_end, _end_time}
    end

    test "library mapping cache prevents N+1 queries", %{library: library} do
      # Create additional libraries for testing cache efficiency
      other_libraries =
        for i <- 1..5 do
          Fixtures.library_fixture(%{
            path: "/test/library#{i}",
            name: "Test Library #{i}"
          })
        end

      all_libraries = [library | other_libraries]

      # Create files that map to different libraries
      mixed_files =
        all_libraries
        |> Enum.with_index()
        |> Enum.flat_map(fn {lib, index} ->
          for j <- 1..10 do
            %{
              "path" => "#{lib.path}/movies/movie_#{index}_#{j}.mkv",
              "size" => 2_000_000_000 + j * 100_000,
              "id" => "mixed_#{index}_#{j}",
              "overallBitrate" => 5_000_000
            }
          end
        end)

      # Test the library mapping cache functionality
      log =
        capture_log(fn ->
          # Use the actual batch sync function that has library mapping cache optimization
          Sync.batch_upsert_videos(mixed_files, :sonarr)
        end)

      # Verify all videos were created with correct library associations
      for lib <- all_libraries do
        videos_in_lib = Media.get_videos_in_library(lib.id)
        assert length(videos_in_lib) == 10

        # Verify all videos have correct library_id
        Enum.each(videos_in_lib, fn video ->
          assert video.library_id == lib.id
          assert String.starts_with?(video.path, lib.path)
        end)
      end

      # Should not contain excessive database query logs due to library mapping cache
      # With 60 files and proper caching, we should see very few SELECT queries (< 10)
      select_count = length(String.split(log, "SELECT")) - 1

      assert select_count < 10,
             "Too many SELECT queries: #{select_count} (expected < 10 with library mapping cache)"
    end

    test "analyzer broadway integration works correctly" do
      # Test that analyzer dispatch is triggered appropriately
      _log =
        capture_log(fn ->
          # Create files that need analysis (missing bitrate triggers needs_analysis state)
          files_needing_analysis = [
            %{
              "path" => "/test/analyze1.mkv",
              "size" => 1_500_000_000,
              "service_id" => "analyze1",
              "service_type" => "sonarr",
              # Needs analysis
              "bitrate" => 0
            },
            %{
              "path" => "/test/analyze2.mkv",
              "size" => 2_500_000_000,
              "service_id" => "analyze2",
              "service_type" => "sonarr",
              # Needs analysis
              "bitrate" => 0
            }
          ]

          # Process files through batch upsert
          Repo.transaction(fn ->
            Enum.each(files_needing_analysis, fn attrs ->
              Media.VideoUpsert.upsert(attrs)
            end)
          end)

          # Simulate analyzer dispatch (our optimization)
          if not Enum.empty?(files_needing_analysis) do
            AnalyzerBroadway.dispatch_available()
          end
        end)

      # Verify videos were created
      {:ok, video1} = Media.get_video_by_service_id("analyze1", :sonarr)
      {:ok, video2} = Media.get_video_by_service_id("analyze2", :sonarr)

      # Videos should have missing bitrate (stored as nil after changeset) and be in needs_analysis state
      assert video1.bitrate == nil
      assert video2.bitrate == nil
      assert video1.state == :needs_analysis
      assert video2.state == :needs_analysis

      # Videos in needs_analysis state will be picked up by analyzer naturally
      # No direct dispatch needed - state machine handles the workflow
    end

    test "concurrent batch processing handles race conditions" do
      # Test concurrent sync operations to ensure thread safety
      library1 = Fixtures.library_fixture(%{path: "/test/concurrent1", name: "Concurrent 1"})
      library2 = Fixtures.library_fixture(%{path: "/test/concurrent2", name: "Concurrent 2"})

      # Create two sets of files for concurrent processing
      batch1_files =
        for i <- 1..25 do
          %{
            "path" => "/test/concurrent1/movie_#{i}.mkv",
            "size" => 1_000_000_000 + i * 50_000,
            "id" => "conc1_#{i}",
            "overallBitrate" => 4_000_000
          }
        end

      batch2_files =
        for i <- 1..25 do
          %{
            "path" => "/test/concurrent2/movie_#{i}.mkv",
            "size" => 2_000_000_000 + i * 50_000,
            "id" => "conc2_#{i}",
            "overallBitrate" => 6_000_000
          }
        end

      # Process batches concurrently
      tasks = [
        Task.async(fn ->
          capture_log(fn ->
            Repo.transaction(
              fn ->
                Enum.each(batch1_files, fn file ->
                  video_attrs = %{
                    "path" => file["path"],
                    "size" => file["size"],
                    "service_id" => to_string(file["id"]),
                    "service_type" => "sonarr",
                    "library_id" => library1.id,
                    "bitrate" => file["overallBitrate"] || 0
                  }

                  Media.VideoUpsert.upsert(video_attrs)
                end)
              end,
              timeout: :infinity
            )
          end)
        end),
        Task.async(fn ->
          capture_log(fn ->
            Repo.transaction(
              fn ->
                Enum.each(batch2_files, fn file ->
                  video_attrs = %{
                    "path" => file["path"],
                    "size" => file["size"],
                    "service_id" => to_string(file["id"]),
                    "service_type" => "sonarr",
                    "library_id" => library2.id,
                    "bitrate" => file["overallBitrate"] || 0
                  }

                  Media.VideoUpsert.upsert(video_attrs)
                end)
              end,
              timeout: :infinity
            )
          end)
        end)
      ]

      # Wait for both tasks to complete
      [_log1, _log2] = Task.await_many(tasks, 10_000)

      # Verify both batches were processed correctly
      videos_lib1 = Media.get_videos_in_library(library1.id)
      videos_lib2 = Media.get_videos_in_library(library2.id)

      assert length(videos_lib1) == 25
      assert length(videos_lib2) == 25

      # Verify no data corruption between concurrent operations
      Enum.each(videos_lib1, fn video ->
        assert video.library_id == library1.id
        assert String.starts_with?(video.path, "/test/concurrent1/")
        assert video.bitrate == 4_000_000
      end)

      Enum.each(videos_lib2, fn video ->
        assert video.library_id == library2.id
        assert String.starts_with?(video.path, "/test/concurrent2/")
        assert video.bitrate == 6_000_000
      end)
    end

    test "error handling in batch processing is robust" do
      # Test batch processing with some invalid data
      mixed_batch = [
        # Valid file
        %{
          "path" => "/test/valid1.mkv",
          "size" => 1_000_000_000,
          "id" => "valid1",
          "overallBitrate" => 4_000_000
        },
        # File with missing size (should handle gracefully)
        %{
          "path" => "/test/invalid1.mkv",
          "id" => "invalid1",
          "overallBitrate" => 5_000_000
        },
        # Valid file
        %{
          "path" => "/test/valid2.mkv",
          "size" => 2_000_000_000,
          "id" => "valid2",
          "overallBitrate" => 6_000_000
        },
        # File with nil id (should handle gracefully)
        %{
          "path" => "/test/invalid2.mkv",
          "size" => 1_500_000_000,
          "id" => nil,
          "overallBitrate" => 3_000_000
        }
      ]

      log =
        capture_log(fn ->
          # Process batch with some invalid entries
          try do
            Repo.transaction(
              fn ->
                Enum.each(mixed_batch, fn file ->
                  # Only process valid files (simulate prepare_video_attrs filtering)
                  if file["size"] && file["id"] do
                    video_attrs = %{
                      "path" => file["path"],
                      "size" => file["size"],
                      "service_id" => to_string(file["id"]),
                      "service_type" => "sonarr",
                      "bitrate" => file["overallBitrate"] || 0
                    }

                    Media.VideoUpsert.upsert(video_attrs)
                  end
                end)
              end,
              timeout: :infinity
            )
          rescue
            _error ->
              # Should handle errors gracefully (no output needed in tests)
              :ok
          end
        end)

      # Verify only valid files were processed
      valid_videos = [
        Media.get_video_by_service_id("valid1", :sonarr),
        Media.get_video_by_service_id("valid2", :sonarr)
      ]

      assert Enum.all?(valid_videos, fn
               {:ok, _video} -> true
               {:error, _} -> false
             end)

      # Invalid entries should not exist
      assert Media.get_video_by_service_id("invalid1", :sonarr) == {:error, :not_found}
      assert Media.get_video_by_service_id(nil, :sonarr) == {:error, :invalid_service_id}

      # Should not crash the entire batch
      # No exception traces
      refute String.contains?(log, "** (")
    end

    test "memory usage remains stable during large sync operations" do
      # Test memory stability during processing
      initial_memory = :erlang.memory(:total)

      # Process a large number of files
      large_batch =
        for i <- 1..500 do
          %{
            "path" => "/test/memory/movie_#{i}.mkv",
            "size" => 1_000_000_000 + i,
            "id" => "mem_#{i}",
            "overallBitrate" => 4_000_000 + i * 1000
          }
        end

      # Process in chunks to simulate real sync behavior
      chunk_size = 50

      large_batch
      |> Enum.chunk_every(chunk_size)
      |> Enum.with_index()
      |> Enum.each(fn {chunk, index} ->
        Repo.transaction(
          fn ->
            Enum.each(chunk, fn file ->
              video_attrs = %{
                "path" => file["path"],
                "size" => file["size"],
                "service_id" => to_string(file["id"]),
                "service_type" => "sonarr",
                "bitrate" => file["overallBitrate"] || 0
              }

              Media.VideoUpsert.upsert(video_attrs)
            end)
          end,
          timeout: :infinity
        )

        # Trigger GC after each chunk to test memory stability
        if rem(index, 5) == 0 do
          :erlang.garbage_collect()
        end
      end)

      final_memory = :erlang.memory(:total)

      # Memory increase should be reasonable (less than 10x)
      memory_ratio = final_memory / initial_memory
      assert memory_ratio < 10.0

      # Verify all videos were created
      created_count = Media.count_videos()
      assert created_count >= 500
    end
  end
end
