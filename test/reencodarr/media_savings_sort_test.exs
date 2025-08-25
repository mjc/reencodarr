defmodule Reencodarr.MediaSavingsSortTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.Media

  describe "encoding queue sorting by savings" do
    setup do
      # Create a test library first
      {:ok, library} = Media.create_library(%{path: "/test/library", monitor: true})

      # Create test videos with same size but different savings
      video1 =
        Fixtures.video_fixture(%{
          path: "/test/library/small_savings.mp4",
          size: 1_000_000_000,
          bitrate: 5000,
          service_type: "sonarr",
          service_id: "1",
          library_id: library.id,
          # Required analysis fields
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          width: 1920,
          height: 1080,
          duration: 7200.0,
          state: :analyzed
        })

      video2 =
        Fixtures.video_fixture(%{
          path: "/test/library/large_savings.mp4",
          size: 1_000_000_000,
          bitrate: 5000,
          service_type: "sonarr",
          service_id: "2",
          library_id: library.id,
          # Required analysis fields
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          width: 1920,
          height: 1080,
          duration: 7200.0,
          state: :analyzed
        })

      video3 =
        Fixtures.video_fixture(%{
          path: "/test/library/medium_savings.mp4",
          size: 1_000_000_000,
          bitrate: 5000,
          service_type: "sonarr",
          service_id: "3",
          library_id: library.id,
          # Required analysis fields
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          width: 1920,
          height: 1080,
          duration: 7200.0,
          state: :analyzed
        })

      %{video1: video1, video2: video2, video3: video3}
    end

    test "sorts encoding queue by savings (highest first)", %{
      video1: video1,
      video2: video2,
      video3: video3
    } do
      # Create VMAFs with different savings but same size
      {:ok, vmaf1} =
        Media.upsert_vmaf(%{
          "video_id" => video1.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 10% savings = 100MB
          "percent" => "90",
          "chosen" => true,
          "params" => []
        })

      {:ok, vmaf2} =
        Media.upsert_vmaf(%{
          "video_id" => video2.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 50% savings = 500MB
          "percent" => "50",
          "chosen" => true,
          "params" => []
        })

      {:ok, vmaf3} =
        Media.upsert_vmaf(%{
          "video_id" => video3.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 30% savings = 300MB
          "percent" => "70",
          "chosen" => true,
          "params" => []
        })

      # Verify savings were calculated correctly
      # 100MB
      assert vmaf1.savings == 100_000_000
      # 500MB
      assert vmaf2.savings == 500_000_000
      # 300MB
      assert vmaf3.savings == 300_000_000

      # Test encoding queue sorting - should return highest savings first
      encoding_queue = Media.list_videos_by_estimated_percent(3)

      # Should be ordered: video2 (500MB), video3 (300MB), video1 (100MB)
      assert length(encoding_queue) == 3
      assert Enum.at(encoding_queue, 0).video.id == video2.id
      assert Enum.at(encoding_queue, 1).video.id == video3.id
      assert Enum.at(encoding_queue, 2).video.id == video1.id

      # Verify savings order
      savings_order = Enum.map(encoding_queue, & &1.savings)
      assert savings_order == [500_000_000, 300_000_000, 100_000_000]
    end

    test "get_next_for_encoding returns highest savings first", %{video1: video1, video2: video2} do
      # Create VMAFs with different savings
      {:ok, _vmaf1} =
        Media.upsert_vmaf(%{
          "video_id" => video1.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 20% savings = 200MB
          "percent" => "80",
          "chosen" => true,
          "params" => []
        })

      {:ok, _vmaf2} =
        Media.upsert_vmaf(%{
          "video_id" => video2.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 40% savings = 400MB
          "percent" => "60",
          "chosen" => true,
          "params" => []
        })

      # Should return video2 with higher savings first
      next_encoding = Media.get_next_for_encoding()
      assert next_encoding.video.id == video2.id
      assert next_encoding.savings == 400_000_000
    end

    test "get_next_for_encoding_by_time still prioritizes savings over time", %{
      video1: video1,
      video2: video2
    } do
      # Create VMAFs where video1 has shorter time but lower savings
      {:ok, _vmaf1} =
        Media.upsert_vmaf(%{
          "video_id" => video1.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 15% savings = 150MB
          "percent" => "85",
          "chosen" => true,
          # Shorter encoding time
          "time" => 100,
          "params" => []
        })

      {:ok, _vmaf2} =
        Media.upsert_vmaf(%{
          "video_id" => video2.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 60% savings = 600MB
          "percent" => "40",
          "chosen" => true,
          # Longer encoding time
          "time" => 200,
          "params" => []
        })

      # Should return video2 with higher savings despite longer time
      next_encoding = Media.get_next_for_encoding_by_time()
      assert next_encoding.video.id == video2.id
      assert next_encoding.savings == 600_000_000
    end

    test "handles nil savings gracefully in sorting", %{video1: video1, video2: video2} do
      # Create one VMAF with savings and one without
      {:ok, _vmaf1} =
        Media.upsert_vmaf(%{
          "video_id" => video1.id,
          "crf" => 25.0,
          "score" => 95.0,
          "chosen" => true,
          "params" => []
          # No percent, so no savings calculation
        })

      {:ok, _vmaf2} =
        Media.upsert_vmaf(%{
          "video_id" => video2.id,
          "crf" => 25.0,
          "score" => 95.0,
          # 30% savings
          "percent" => "70",
          "chosen" => true,
          "params" => []
        })

      # Should prioritize the one with savings
      encoding_queue = Media.list_videos_by_estimated_percent(2)
      assert length(encoding_queue) == 2

      # Video with savings should come first
      first_vmaf = Enum.at(encoding_queue, 0)
      assert first_vmaf.video.id == video2.id
      assert first_vmaf.savings == 300_000_000

      # Video without savings should come second
      second_vmaf = Enum.at(encoding_queue, 1)
      assert second_vmaf.video.id == video1.id
      assert second_vmaf.savings == nil
    end
  end
end
