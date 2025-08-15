defmodule Reencodarr.SavingsIntegrationTest do
  @moduledoc """
  Integration test to verify savings functionality end-to-end.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.{Media, Repo}

  describe "savings integration" do
    test "savings flow from CRF search to encoding queue" do
      # Create a test library first
      {:ok, library} = Media.create_library(%{path: "/test/library", monitor: true})

      # Create a test video
      {:ok, video} =
        Media.create_video(%{
          path: "/test/library/integration_video_#{System.unique_integer([:positive])}.mkv",
          # 2GB
          size: 2_000_000_000,
          bitrate: 8000,
          service_type: "sonarr",
          service_id: "1",
          library_id: library.id,
          # Required analysis fields
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          width: 1920,
          height: 1080,
          duration: 7200.0
        })

      # Simulate CRF search results being saved
      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "22.0",
          "score" => "95.2",
          # 30% savings = 600MB
          "percent" => "70",
          "chosen" => true,
          "params" => ["--preset", "medium"],
          "target" => 95
        })

      # Verify savings calculation
      assert vmaf.savings == 600_000_000
      assert vmaf.score == 95.2

      # Verify video is now in encoding queue
      next_video = Media.get_next_for_encoding()
      assert next_video != nil
      assert next_video.video.id == video.id
      assert next_video.id == vmaf.id

      # Verify queue count
      queue_count = Media.encoding_queue_count()
      assert queue_count == 1

      # Create another video with higher savings to test sorting
      {:ok, video2} =
        Media.create_video(%{
          path: "/test/library/high_savings_video_#{System.unique_integer([:positive])}.mkv",
          # 3GB
          size: 3_000_000_000,
          bitrate: 10_000,
          service_type: "sonarr",
          service_id: "2",
          library_id: library.id,
          # Required analysis fields
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          width: 1920,
          height: 1080,
          duration: 7200.0
        })

      {:ok, _vmaf3} =
        Media.upsert_vmaf(%{
          "video_id" => video2.id,
          "crf" => "23.0",
          "score" => "95.8",
          # 20% of original = 80% savings = 2.4GB
          "percent" => "20",
          "chosen" => true,
          "params" => ["--preset", "slow"],
          "target" => 95
        })

      # Now the queue should prioritize video2 (higher savings)
      next_video_updated = Media.get_next_for_encoding()
      assert next_video_updated != nil
      assert next_video_updated.video.path == video2.path

      # Mark video2 as reencoded and verify video1 comes next
      Repo.update!(Ecto.Changeset.change(video2, reencoded: true))
      next_after_video2 = Media.get_next_for_encoding()
      assert next_after_video2 != nil
      assert next_after_video2.video.path == video.path

      # Verify queue count
      queue_count = Media.encoding_queue_count()
      # Only video1 available (video2 is reencoded)
      assert queue_count == 1
    end

    test "savings calculation handles edge cases" do
      # Create a test library first
      {:ok, library} = Media.create_library(%{path: "/test/library", monitor: true})

      # Test with very small file
      {:ok, small_video} =
        Media.create_video(%{
          path: "/test/library/small_video.mp4",
          # 100KB
          size: 100_000,
          bitrate: 1000,
          service_type: "sonarr",
          service_id: "2",
          library_id: library.id,
          # Required analysis fields
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          width: 1920,
          height: 1080,
          duration: 7200.0
        })

      {:ok, small_vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => small_video.id,
          "crf" => "28.0",
          "score" => "94.0",
          # 40% savings = 40KB
          "percent" => "60",
          "chosen" => true,
          "params" => ["--preset", "fast"],
          "target" => 95
        })

      assert small_vmaf.savings == 40_000

      # Test with near-perfect compression
      {:ok, perfect_video} =
        Media.create_video(%{
          path: "/test/library/perfect_compression.mkv",
          # 1GB
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
          duration: 7200.0
        })

      {:ok, perfect_vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => perfect_video.id,
          "crf" => "18.0",
          "score" => "98.0",
          # 95% savings = 950MB
          "percent" => "5",
          "chosen" => true,
          "params" => ["--preset", "slow"],
          "target" => 95
        })

      assert perfect_vmaf.savings == 950_000_000

      # Verify queue sorting prioritizes higher absolute savings
      next_video = Media.get_next_for_encoding()
      # 950MB > 40KB, so perfect_video should come first
      assert next_video != nil
      assert next_video.video.path == perfect_video.path
    end

    test "explicit savings override calculation" do
      # Create a test library first
      {:ok, library} = Media.create_library(%{path: "/test/library", monitor: true})

      # Create test video
      {:ok, video} =
        Media.create_video(%{
          path: "/test/library/explicit_savings_video.mp4",
          size: 500_000_000,
          bitrate: 3000,
          service_type: "sonarr",
          service_id: "4",
          library_id: library.id,
          # Required analysis fields
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          width: 1920,
          height: 1080,
          duration: 7200.0
        })

      # Explicit savings value (different from calculated)
      explicit_savings = 123_456_789

      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "20.0",
          "score" => "96.5",
          "percent" => "40",
          "savings" => explicit_savings,
          "chosen" => true,
          "params" => ["--preset", "medium"],
          "target" => 95
        })

      # Verify explicit savings was used
      assert vmaf.savings == explicit_savings

      # Reload from database and verify persistence
      reloaded_vmaf = Repo.get(Media.Vmaf, vmaf.id)
      assert reloaded_vmaf.savings == explicit_savings

      # Update VMAF and verify savings is preserved
      {:ok, updated_vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "21.0",
          # Updated score
          "score" => "97.5",
          "percent" => "25",
          "savings" => explicit_savings,
          "chosen" => true,
          "params" => ["--preset", "medium"],
          "target" => 95
        })

      assert updated_vmaf.savings == explicit_savings
      assert updated_vmaf.score == 97.5
    end
  end
end
