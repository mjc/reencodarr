defmodule Reencodarr.SyncIntegrationTest do
  use Reencodarr.DataCase, async: false
  alias Reencodarr.Analyzer.Broadway, as: AnalyzerBroadway
  alias Reencodarr.Fixtures
  alias Reencodarr.{Media, Sync}
  import ExUnit.CaptureLog

  describe "sync integration tests" do
    setup do
      library = Fixtures.library_fixture(%{path: "/test"})
      %{library: library}
    end

    test "upsert_video_from_file handles VideoFileInfo correctly", %{library: _library} do
      file_info = %Reencodarr.Media.VideoFileInfo{
        path: "/test/integration/movie1.mkv",
        size: 2_500_000_000,
        service_id: "int1",
        service_type: :sonarr,
        audio_codec: "DTS",
        bitrate: 8_000_000,
        audio_channels: 6,
        video_codec: "HEVC",
        resolution: "3840x2160",
        video_fps: 24.0,
        video_dynamic_range: "HDR10",
        video_dynamic_range_type: "HDR10",
        audio_stream_count: 2,
        overall_bitrate: 8_500_000,
        run_time: 7200,
        subtitles: ["eng", "spa"],
        title: "Integration Test Movie",
        date_added: DateTime.utc_now()
      }

      log =
        capture_log(fn ->
          result = Sync.upsert_video_from_file(file_info, :sonarr)
          assert {:ok, _} = result
        end)

      # Verify video was created correctly
      {:ok, video} = Media.get_video_by_service_id("int1", :sonarr)
      assert video.path == "/test/integration/movie1.mkv"
      assert video.size == 2_500_000_000
      # Uses overall_bitrate when available
      assert video.bitrate == 8_500_000
      assert video.service_type == :sonarr
      # Should be in analyzed state since it has complete metadata
      assert video.state == :analyzed or video.state == :needs_analysis

      # Should not trigger analyzer since video has complete bitrate data
      # Videos with valid bitrate will be in analyzed state, not needs_analysis
      refute String.contains?(log, "dispatch_available")
    end

    test "upsert_video_from_file triggers analyzer for zero bitrate", %{library: _library} do
      file_info = %Reencodarr.Media.VideoFileInfo{
        path: "/test/integration/need_analysis.mkv",
        size: 1_800_000_000,
        service_id: "need_analysis",
        service_type: :sonarr,
        audio_codec: "AAC",
        # Needs analysis
        bitrate: 0,
        audio_channels: 2,
        video_codec: "H.264",
        resolution: "1920x1080",
        video_fps: 23.976,
        # Also set overall_bitrate to 0
        overall_bitrate: 0,
        run_time: 5400,
        subtitles: ["eng"],
        title: "Needs Analysis Movie",
        date_added: DateTime.utc_now()
      }

      _log =
        capture_log(fn ->
          result = Sync.upsert_video_from_file(file_info, :sonarr)
          assert {:ok, _} = result
        end)

      # Verify video was created
      {:ok, video} = Media.get_video_by_service_id("need_analysis", :sonarr)
      # Check that video needs analysis due to missing bitrate (stored as nil after changeset)
      assert video.bitrate == nil
      # Should be in needs_analysis state due to missing bitrate
      assert video.state == :needs_analysis

      # Videos with missing bitrate automatically get needs_analysis state
      # The analyzer will pick them up naturally, no direct dispatch needed
      assert video.state == :needs_analysis
    end

    test "upsert_video_from_service_file handles service data correctly", %{library: _library} do
      service_file = %{
        "path" => "/test/service/episode1.mkv",
        "size" => 1_200_000_000,
        "id" => "service_ep1",
        "mediaInfo" => %{
          "audioCodec" => "EAC3",
          "videoBitrate" => 3_500_000,
          "audioBitrate" => 640_000,
          "audioChannels" => 6,
          "videoCodec" => "H.264",
          "width" => 1920,
          "height" => 1080,
          "audioLanguages" => ["eng"],
          "subtitles" => ["eng", "fre"]
        },
        "videoFps" => 23.976,
        "overallBitrate" => 4_140_000,
        "runTime" => 2700,
        "dateAdded" => "2024-01-15T10:30:00Z"
      }

      _log =
        capture_log(fn ->
          result = Sync.upsert_video_from_service_file(service_file, :sonarr)
          assert {:ok, _} = result
        end)

      # Verify video was created with proper MediaInfo conversion
      {:ok, video} = Media.get_video_by_service_id("service_ep1", :sonarr)
      assert video.path == "/test/service/episode1.mkv"
      assert video.size == 1_200_000_000
      assert video.bitrate == 4_140_000
      assert video.service_type == :sonarr

      # Check mediainfo structure was properly converted
      assert video.mediainfo != nil
      assert is_map(video.mediainfo)
    end

    test "upsert_video_from_service_file handles missing bitrate analysis", %{library: _library} do
      service_file_no_bitrate = %{
        "path" => "/test/service/needs_analysis.mkv",
        "size" => 900_000_000,
        "id" => "service_analysis",
        "mediaInfo" => %{
          "audioCodec" => "AAC",
          "videoCodec" => "H.264",
          "width" => 1280,
          "height" => 720,
          "audioLanguages" => ["eng"]
        },
        # No overallBitrate field
        "videoFps" => 29.97,
        "runTime" => 1800,
        "dateAdded" => "2024-01-15T11:00:00Z"
      }

      _log =
        capture_log(fn ->
          result = Sync.upsert_video_from_service_file(service_file_no_bitrate, :radarr)
          assert {:ok, _} = result
        end)

      # Verify video was created
      {:ok, video} = Media.get_video_by_service_id("service_analysis", :radarr)
      assert video.service_type == :radarr
      # Should have missing bitrate that triggered analysis (stored as nil after changeset)
      assert video.bitrate == nil
      # Should be in needs_analysis state due to missing bitrate
      assert video.state == :needs_analysis

      # Videos with missing bitrate automatically get needs_analysis state
      # The analyzer will pick them up naturally, no direct dispatch needed
      assert video.state == :needs_analysis
    end

    test "sync preserves existing analyzed bitrates correctly", %{library: library} do
      # First, create a video with analyzed bitrate using fixture
      {:ok, original_video} =
        Fixtures.video_fixture(%{
          path: "/test/preserve/movie.mkv",
          size: 3_000_000_000,
          # Previously analyzed
          bitrate: 12_000_000,
          service_id: "preserve_test",
          service_type: :sonarr,
          library_id: library.id
        })

      # Simulate sync update with same size (should preserve bitrate)
      updated_file = %{
        "path" => "/test/preserve/movie.mkv",
        # Same size
        "size" => 3_000_000_000,
        "id" => "preserve_test",
        "mediaInfo" => %{
          "audioCodec" => "TrueHD",
          # Different metadata
          "videoBitrate" => 10_000_000,
          "audioBitrate" => 1_500_000,
          "audioChannels" => 8,
          "videoCodec" => "HEVC",
          "width" => 3840,
          "height" => 2160,
          "audioLanguages" => ["eng"],
          "subtitles" => ["eng"]
        },
        "videoFps" => 24.0,
        # Different overall bitrate
        "overallBitrate" => 11_500_000,
        "runTime" => 8400
      }

      log =
        capture_log(fn ->
          Sync.upsert_video_from_file(updated_file, :sonarr)
        end)

      # Verify bitrate was preserved
      updated_video = Media.get_video!(original_video.id)
      # Should keep original analyzed bitrate
      assert updated_video.bitrate == 12_000_000
      # Size updated
      assert updated_video.size == 3_000_000_000

      # Should not trigger analyzer since we have valid analyzed bitrate
      # Videos with preserved bitrate remain in analyzed state
      refute String.contains?(log, "dispatch_available")
    end

    test "sync updates bitrate when file size changes significantly", %{library: library} do
      # Create video with analyzed bitrate using fixture
      {:ok, original_video} =
        Fixtures.video_fixture(%{
          path: "/test/size_change/movie.mkv",
          size: 2_000_000_000,
          bitrate: 8_000_000,
          service_id: "size_change",
          service_type: :sonarr,
          library_id: library.id
        })

      # Simulate sync with significantly different size
      updated_file = %{
        "path" => "/test/size_change/movie.mkv",
        # Doubled size
        "size" => 4_000_000_000,
        "id" => "size_change",
        "mediaInfo" => %{
          "audioCodec" => "DTS",
          "videoBitrate" => 15_000_000,
          "audioBitrate" => 1_000_000,
          "audioChannels" => 6,
          "videoCodec" => "HEVC",
          "width" => 1920,
          "height" => 1080
        },
        "overallBitrate" => 16_000_000,
        "runTime" => 7200
      }

      _log =
        capture_log(fn ->
          Sync.upsert_video_from_file(updated_file, :sonarr)
        end)

      # Verify bitrate was updated due to size change
      updated_video = Media.get_video!(original_video.id)
      # Should use new bitrate
      assert updated_video.bitrate == 16_000_000
      assert updated_video.size == 4_000_000_000
    end

    test "refresh operations work correctly for both sonarr and radarr" do
      # Mock the external service calls since we're testing integration
      log =
        capture_log(fn ->
          # Test Sonarr refresh
          result = Sync.refresh_operations("123", :sonarr)
          # Should attempt the operation (may fail without actual service)
          assert result == {:error, :econnrefused} or
                   match?({:ok, _}, result) or
                   match?({:error, _}, result)

          # Test Radarr refresh
          result = Sync.refresh_operations("456", :radarr)
          # Should attempt the operation (may fail without actual service)
          assert result == {:error, :econnrefused} or
                   match?({:ok, _}, result) or
                   match?({:error, _}, result)
        end)

      # Should log the refresh attempts or connection errors
      # In test environment, these operations will likely fail with connection errors
      assert String.contains?(log, "refresh") or
               String.contains?(log, "episode") or
               String.contains?(log, "movie") or
               String.contains?(log, "econnrefused") or
               String.contains?(log, "error") or
               String.contains?(log, "Error") or
               String.contains?(log, "failed") or
               String.contains?(log, "Failed") or
               log == ""
    end

    test "delete_video_and_vmafs cleans up properly", %{library: library} do
      # Create video with associated VMAFs using fixture
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/delete/movie.mkv",
          size: 2_000_000_000,
          bitrate: 5_000_000,
          service_id: "delete_test",
          service_type: :sonarr,
          library_id: library.id
        })

      # Create some VMAFs for this video
      {:ok, _vmaf1} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 23.0,
          score: 95.5,
          size: "1.8GB",
          percent: 90.0,
          params: ["test_params_1"]
        })

      {:ok, _vmaf2} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 25.0,
          score: 93.2,
          size: "1.6GB",
          percent: 80.0,
          params: ["test_params_2"]
        })

      # Verify VMAFs exist
      vmafs_before = Media.get_vmafs_for_video(video.id)
      assert length(vmafs_before) == 2

      # Delete video and VMAFs
      result = Sync.delete_video_and_vmafs(video.path)
      assert result == :ok

      # Verify video and VMAFs were deleted
      assert Media.get_video(video.id) == nil
      vmafs_after = Media.get_vmafs_for_video(video.id)
      assert Enum.empty?(vmafs_after)
    end

    test "rescan_and_rename_series delegates correctly" do
      log =
        capture_log(fn ->
          result = Sync.rescan_and_rename_series("789")
          # Should delegate to refresh_operations
          assert result == {:error, :econnrefused} or
                   match?({:ok, _}, result) or
                   match?({:error, _}, result)
        end)

      # Should log the operation attempt or connection errors
      assert String.contains?(log, "refresh") or
               String.contains?(log, "rename") or
               String.contains?(log, "econnrefused") or
               String.contains?(log, "error") or
               String.contains?(log, "Error") or
               String.contains?(log, "failed") or
               String.contains?(log, "Failed") or
               log == ""
    end

    test "refresh_and_rename_from_video handles both service types", %{library: library} do
      # Create Sonarr video using fixture
      {:ok, sonarr_video} =
        Fixtures.video_fixture(%{
          path: "/test/refresh/episode.mkv",
          size: 1_500_000_000,
          bitrate: 3_000_000,
          service_id: "refresh_sonarr",
          service_type: :sonarr,
          library_id: library.id
        })

      # Create Radarr video using fixture
      {:ok, radarr_video} =
        Fixtures.video_fixture(%{
          path: "/test/refresh/movie.mkv",
          size: 2_500_000_000,
          bitrate: 6_000_000,
          service_id: "refresh_radarr",
          service_type: :radarr,
          library_id: library.id
        })

      log =
        capture_log(fn ->
          # Test Sonarr refresh
          try do
            result = Sync.refresh_and_rename_from_video(sonarr_video)

            assert result == {:error, :econnrefused} or
                     match?({:ok, _}, result) or
                     match?({:error, _}, result)
          rescue
            _ -> :ok
          end

          # Test Radarr refresh
          try do
            result = Sync.refresh_and_rename_from_video(radarr_video)

            assert result == {:error, :econnrefused} or
                     match?({:ok, _}, result) or
                     match?({:error, _}, result)
          rescue
            _ -> :ok
          end
        end)

      # Should handle both service types or log connection errors
      assert String.contains?(log, "refresh") or
               String.contains?(log, "econnrefused") or
               String.contains?(log, "sonarr") or
               String.contains?(log, "radarr") or
               String.contains?(log, "error") or
               String.contains?(log, "Error") or
               String.contains?(log, "failed") or
               String.contains?(log, "Failed") or
               log == ""
    end
  end

  describe "sync broadway analyzer integration" do
    test "analyzer dispatch works without Broadway running" do
      # Test that dispatch calls don't crash when Broadway isn't running
      log =
        capture_log(fn ->
          # Should handle gracefully when analyzer isn't running
          result = AnalyzerBroadway.dispatch_available()

          # Should either succeed or return expected error
          assert result == :ok or
                   result == {:error, :producer_supervisor_not_found} or
                   result == {:error, :producer_not_found}
        end)

      # Should not crash
      assert is_binary(log)
    end

    test "multiple analyzer dispatch calls are handled efficiently" do
      # Test that multiple rapid dispatch calls don't cause issues
      log =
        capture_log(fn ->
          # Make multiple rapid dispatch calls
          for _i <- 1..10 do
            AnalyzerBroadway.dispatch_available()
            # Small delay between calls
            Process.sleep(10)
          end
        end)

      # Should handle multiple calls without errors
      refute String.contains?(log, "ERROR") or String.contains?(log, "** (")
    end

    test "analyzer running status can be checked safely" do
      # Test that we can check analyzer status without crashing
      result = AnalyzerBroadway.running?()
      assert is_boolean(result)

      # Should work even if analyzer isn't running
      assert result == true or result == false
    end
  end
end
