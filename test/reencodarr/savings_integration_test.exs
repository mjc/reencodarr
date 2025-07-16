defmodule Reencodarr.SavingsIntegrationTest do
  @moduledoc """
  Integration test to verify savings functionality end-to-end.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.{Media, Repo}

  describe "savings integration" do
    test "savings flow from CRF search to encoding queue" do
      # Create a test video
      {:ok, video} =
        Media.create_video(%{
          path: "/test/integration_video.mkv",
          # 2GB
          size: 2_000_000_000,
          bitrate: 8000
        })

      # Simulate CRF search results with different compression ratios
      {:ok, vmaf1} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "22.0",
          "score" => "96.5",
          # 30% of original = 70% savings = 1.4GB
          "percent" => "30",
          "chosen" => false,
          "params" => ["--preset", "slow"],
          "target" => 95
        })

      {:ok, vmaf2} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "24.0",
          "score" => "95.2",
          # 45% of original = 55% savings = 1.1GB
          "percent" => "45",
          # This is the chosen one
          "chosen" => true,
          "params" => ["--preset", "slow"],
          "target" => 95
        })

      # Verify savings were calculated correctly
      # 1.4GB
      assert vmaf1.savings == 1_400_000_000
      # 1.1GB
      assert vmaf2.savings == 1_100_000_000

      # Verify the video shows up in encoding queue (has chosen VMAF)
      next_video = Media.get_next_for_encoding()
      assert next_video != nil
      assert next_video.video.path == video.path

      # Create another video with higher savings to test sorting
      {:ok, video2} =
        Media.create_video(%{
          path: "/test/high_savings_video.mkv",
          # 3GB
          size: 3_000_000_000,
          bitrate: 10_000
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
      # Test with very small file
      {:ok, small_video} =
        Media.create_video(%{
          path: "/test/small_video.mp4",
          # 100KB
          size: 100_000,
          bitrate: 1000
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
          path: "/test/perfect_compression.mkv",
          # 1GB
          size: 1_000_000_000,
          bitrate: 5000
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

    test "savings field is preserved through database operations" do
      {:ok, video} =
        Media.create_video(%{
          path: "/test/persistence_test.mkv",
          # 5GB
          size: 5_000_000_000,
          bitrate: 12_000
        })

      # Create VMAF with explicit savings
      # 3.75GB
      explicit_savings = 3_750_000_000

      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "21.0",
          "score" => "97.2",
          # Would calculate 75% savings = 3.75GB
          "percent" => "25",
          # Explicit value should be used
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
