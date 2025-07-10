defmodule Reencodarr.Dashboard.QueueItemSavingsTest do
  use ExUnit.Case, async: true
  alias Reencodarr.Dashboard.QueueItem

  describe "QueueItem.from_video with savings field" do
    test "uses savings field from database when available" do
      # Mock VMAF struct with savings field
      vmaf_with_savings = %{
        video: %{path: "/test/video.mp4", size: 1_000_000_000},
        percent: 80.0,
        # Pre-calculated savings from database
        savings: 200_000_000,
        estimated_percent: nil
      }

      queue_item = QueueItem.from_video(vmaf_with_savings, 1)

      # Should use the savings field and convert to GB
      expected_savings_gb = 200_000_000 / (1024 * 1024 * 1024)
      assert_in_delta queue_item.estimated_savings_gb, expected_savings_gb, 0.001
      assert queue_item.vmaf_percent == 80.0
      assert queue_item.display_name == "video"
    end

    test "falls back to calculation when savings field is nil" do
      # Mock VMAF struct without savings field
      vmaf_without_savings = %{
        video: %{path: "/test/video.mp4", size: 1_000_000_000},
        percent: 70.0,
        # No pre-calculated savings
        savings: nil,
        estimated_percent: nil
      }

      queue_item = QueueItem.from_video(vmaf_without_savings, 1)

      # Should calculate savings: (100 - 70) / 100 * 1GB = 300MB = 0.279GB
      expected_savings_gb = 1_000_000_000 * (100 - 70) / 100 / (1024 * 1024 * 1024)
      assert_in_delta queue_item.estimated_savings_gb, expected_savings_gb, 0.001
    end

    test "handles zero savings correctly" do
      vmaf_no_savings = %{
        video: %{path: "/test/video.mp4", size: 1_000_000_000},
        # No compression savings
        percent: 100.0,
        savings: 0,
        estimated_percent: nil
      }

      queue_item = QueueItem.from_video(vmaf_no_savings, 1)

      # Should convert 0 bytes to 0 GB
      assert queue_item.estimated_savings_gb == 0.0
    end

    test "handles missing percent gracefully" do
      vmaf_no_percent = %{
        video: %{path: "/test/video.mp4", size: 1_000_000_000},
        # No percent data
        percent: 0,
        savings: nil,
        estimated_percent: nil
      }

      queue_item = QueueItem.from_video(vmaf_no_percent, 1)

      # Should result in nil savings when calculation fails
      assert queue_item.estimated_savings_gb == nil
    end

    test "preserves other VMAF fields correctly" do
      vmaf_complete = %{
        video: %{path: "/path/to/My.Test.Video.2024.1080p.mkv", size: 5_000_000_000},
        percent: 60.0,
        # 2GB savings
        savings: 2_000_000_000,
        estimated_percent: 58.5
      }

      queue_item = QueueItem.from_video(vmaf_complete, 3)

      assert queue_item.index == 3
      assert queue_item.path == "/path/to/My.Test.Video.2024.1080p.mkv"
      # Cleaned name
      assert queue_item.display_name == "My.Test.Video"
      assert queue_item.vmaf_percent == 60.0
      assert queue_item.estimated_percent == 58.5
      assert queue_item.size == 5_000_000_000

      # Check savings conversion
      expected_savings_gb = 2_000_000_000 / (1024 * 1024 * 1024)
      assert_in_delta queue_item.estimated_savings_gb, expected_savings_gb, 0.001
    end

    test "handles video struct (non-VMAF) correctly" do
      # Regular video struct for CRF search queue
      video = %{
        path: "/test/video.mp4",
        size: 1_000_000_000,
        bitrate: 5_000_000,
        estimated_percent: nil
      }

      queue_item = QueueItem.from_video(video, 1)

      # Should not have savings data for non-VMAF structs
      assert queue_item.estimated_savings_gb == nil
      assert queue_item.vmaf_percent == nil
      assert queue_item.bitrate == 5_000_000
      assert queue_item.size == 1_000_000_000
    end
  end

  describe "display name cleaning" do
    test "cleans complex video filenames correctly" do
      complex_vmaf = %{
        video: %{
          path: "/movies/The.Matrix.1999.1080p.BluRay.x264.DTS-HD.mkv",
          size: 8_000_000_000
        },
        percent: 75.0,
        savings: 2_000_000_000,
        estimated_percent: nil
      }

      queue_item = QueueItem.from_video(complex_vmaf, 1)

      # Should clean up the filename significantly
      assert queue_item.display_name == "The.Matrix"
    end

    test "handles various video formats and qualities" do
      test_cases = [
        {"/tv/Show.S01E01.720p.WEBDL.x265.mp4", "Show.S01E01"},
        {"/movies/Film.2023.2160p.4K.UHD.HDR.HEVC.mkv", "Film"},
        {"/content/Documentary.HDTV.XviD.avi", "Documentary"}
      ]

      Enum.each(test_cases, fn {path, expected_name} ->
        vmaf = %{
          video: %{path: path, size: 1_000_000_000},
          percent: 80.0,
          savings: 200_000_000,
          estimated_percent: nil
        }

        queue_item = QueueItem.from_video(vmaf, 1)
        assert queue_item.display_name == expected_name
      end)
    end
  end
end
