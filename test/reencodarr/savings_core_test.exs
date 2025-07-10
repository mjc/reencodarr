defmodule Reencodarr.SavingsCoreTest do
  @moduledoc """
  Core test to verify savings calculation and storage.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.{Media, Repo}

  describe "core savings functionality" do
    test "VMAF upsert calculates and stores savings correctly" do
      # Create test video
      {:ok, video} =
        Media.create_video(%{
          path: "/test/savings_test.mkv",
          # 1GB
          size: 1_000_000_000,
          bitrate: 5000
        })

      # Test different compression ratios
      test_cases = [
        # 50% of original = 50% savings = 500MB
        {50, 500_000_000},
        # 25% of original = 75% savings = 750MB
        {25, 750_000_000},
        # 80% of original = 20% savings = 200MB
        {80, 200_000_000},
        # 10% of original = 90% savings = 900MB
        {10, 900_000_000}
      ]

      for {percent, expected_savings} <- test_cases do
        {:ok, vmaf} =
          Media.upsert_vmaf(%{
            "video_id" => video.id,
            # Vary CRF to avoid conflicts
            "crf" => "#{20 + percent / 10}",
            "score" => "95.0",
            "percent" => "#{percent}",
            "chosen" => false,
            "params" => ["--preset", "medium"],
            "target" => 95
          })

        assert vmaf.savings == expected_savings,
               "Expected #{expected_savings} savings for #{percent}% compression, got #{vmaf.savings}"

        assert vmaf.percent == percent
      end
    end

    test "explicit savings overrides calculation" do
      {:ok, video} =
        Media.create_video(%{
          path: "/test/explicit_savings.mkv",
          # 2GB
          size: 2_000_000_000,
          bitrate: 8000
        })

      # 1.5GB
      explicit_savings = 1_500_000_000

      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "23.0",
          "score" => "95.5",
          # Would calculate 60% = 1.2GB, but explicit should override
          "percent" => "40",
          "savings" => explicit_savings,
          "chosen" => true,
          "params" => ["--preset", "slow"],
          "target" => 95
        })

      # Should use explicit savings, not calculated
      assert vmaf.savings == explicit_savings
      assert vmaf.percent == 40
    end

    test "savings field persists through database operations" do
      {:ok, video} =
        Media.create_video(%{
          path: "/test/persistence.mkv",
          # 3GB
          size: 3_000_000_000,
          bitrate: 10000
        })

      # Create initial VMAF
      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "22.0",
          "score" => "96.0",
          # 70% savings = 2.1GB
          "percent" => "30",
          "chosen" => true,
          "params" => ["--preset", "medium"],
          "target" => 95
        })

      initial_savings = vmaf.savings
      assert initial_savings == 2_100_000_000

      # Reload from database
      reloaded = Repo.get(Media.Vmaf, vmaf.id)
      assert reloaded.savings == initial_savings

      # Update with new score but same savings params
      {:ok, updated} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "22.0",
          # Updated score
          "score" => "96.5",
          # Same percent
          "percent" => "30",
          "chosen" => true,
          "params" => ["--preset", "medium"],
          "target" => 95
        })

      # Savings should remain the same since percent didn't change
      assert updated.savings == initial_savings
      assert updated.score == 96.5
    end

    test "handles edge cases gracefully" do
      # Very small video
      {:ok, small_video} =
        Media.create_video(%{
          path: "/test/small_size.mkv",
          # 1 byte
          size: 1,
          bitrate: 1000
        })

      {:ok, small_vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => small_video.id,
          "crf" => "25.0",
          "score" => "95.0",
          # 50% savings = 0.5 bytes, rounded to 1
          "percent" => "50",
          "chosen" => false,
          "params" => ["--preset", "fast"],
          "target" => 95
        })

      assert small_vmaf.savings == 1

      # Missing percent
      {:ok, video} =
        Media.create_video(%{
          path: "/test/no_percent.mkv",
          size: 1_000_000_000,
          bitrate: 5000
        })

      {:ok, no_percent_vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "24.0",
          "score" => "94.5",
          "chosen" => false,
          "params" => ["--preset", "medium"],
          "target" => 95
          # No percent field
        })

      assert is_nil(no_percent_vmaf.savings)
    end

    test "string percent values are handled correctly" do
      {:ok, video} =
        Media.create_video(%{
          path: "/test/string_percent.mkv",
          # 800MB
          size: 800_000_000,
          bitrate: 4000
        })

      # Test string percent
      {:ok, vmaf} =
        Media.upsert_vmaf(%{
          "video_id" => video.id,
          "crf" => "26.0",
          "score" => "93.8",
          # String "35" should work
          "percent" => "35",
          "chosen" => false,
          "params" => ["--preset", "fast"],
          "target" => 95
        })

      # 35% of original = 65% savings = 520MB
      assert vmaf.savings == 520_000_000
      assert vmaf.percent == 35
    end
  end
end
