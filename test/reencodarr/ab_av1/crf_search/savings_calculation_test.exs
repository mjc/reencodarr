defmodule Reencodarr.AbAv1.CrfSearch.SavingsCalculationTest do
  @moduledoc """
  Tests for space savings calculation in CRF search functionality.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Media

  describe "calculate_savings/2" do
    test "calculates savings correctly for valid inputs through VMAF upsert" do
      # Create a test video
      {:ok, video} =
        Fixtures.video_fixture_with_result(%{
          path: "/test/savings_test.mkv",
          # 1GB
          size: 1_000_000_000,
          bitrate: 5000,
          state: :needs_analysis,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 6,
          atmos: false
        })

      # Test with 50% reduction on 1GB file
      vmaf_params = %{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.5",
        # 50% of original size
        "percent" => "50.0",
        "params" => ["--preset", "medium"],
        "chosen" => false,
        "target" => 95
      }

      {:ok, vmaf} = Media.upsert_vmaf(vmaf_params)

      # Should save 500MB (50% of original)
      expected_savings = 500_000_000
      assert vmaf.savings == expected_savings
    end

    test "handles string percent inputs through VMAF upsert" do
      {:ok, video} =
        Fixtures.video_fixture_with_result(%{
          path: "/test/string_percent.mkv",
          size: 1_000_000_000,
          bitrate: 5000,
          state: :needs_analysis,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 6,
          atmos: false
        })

      # Test with string percent
      vmaf_params = %{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.5",
        # String input
        "percent" => "30",
        "params" => ["--preset", "medium"],
        "chosen" => false,
        "target" => 95
      }

      {:ok, vmaf} = Media.upsert_vmaf(vmaf_params)
      assert vmaf.savings == 700_000_000

      # Test with float string
      vmaf_params2 = %{
        "video_id" => video.id,
        "crf" => "24.0",
        "score" => "95.5",
        # Float string input
        "percent" => "45.5",
        "params" => ["--preset", "medium"],
        "chosen" => false,
        "target" => 95
      }

      {:ok, vmaf2} = Media.upsert_vmaf(vmaf_params2)
      assert vmaf2.savings == 545_000_000
    end

    test "returns nil for invalid inputs through VMAF upsert" do
      {:ok, video} =
        Fixtures.video_fixture_with_result(%{
          path: "/test/invalid_inputs.mkv",
          size: 1_000_000_000,
          bitrate: 5000,
          state: :needs_analysis,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 6,
          atmos: false
        })

      # Test with invalid percent values that would not calculate savings
      # Note: The schema will reject completely invalid strings, so we test edge cases
      edge_case_percents = [0, -10, 101]

      Enum.each(edge_case_percents, fn percent ->
        vmaf_params = %{
          "video_id" => video.id,
          # Random CRF to avoid conflicts
          "crf" => "#{:rand.uniform(10) + 20}.0",
          "score" => "95.5",
          # Convert to string for consistency
          "percent" => "#{percent}",
          "params" => ["--preset", "medium"],
          "chosen" => false,
          "target" => 95
        }

        {:ok, vmaf} = Media.upsert_vmaf(vmaf_params)
        # These should not calculate savings due to invalid percent values
        assert vmaf.savings == nil
      end)

      # Test completely invalid string - this should fail at changeset level
      invalid_vmaf_params = %{
        "video_id" => video.id,
        "crf" => "25.0",
        "score" => "95.5",
        "percent" => "invalid_string",
        "params" => ["--preset", "medium"],
        "chosen" => false,
        "target" => 95
      }

      # This should fail validation
      assert {:error, changeset} = Media.upsert_vmaf(invalid_vmaf_params)
      assert Keyword.has_key?(changeset.errors, :percent)
    end
  end

  describe "VMAF upsert with savings" do
    setup do
      {:ok, video} =
        Fixtures.video_fixture_with_result(%{
          path: "/test/movie.mkv",
          # 1GB video
          size: 1_000_000_000,
          bitrate: 5000,
          state: :needs_analysis,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 6,
          atmos: false
        })

      %{video: video}
    end

    test "upserts VMAF with calculated savings", %{video: video} do
      vmaf_params = %{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.5",
        # 40% of original size = 60% savings
        "percent" => "40",
        "params" => ["--preset", "medium"],
        "chosen" => false,
        "target" => 95
      }

      assert {:ok, vmaf} = Media.upsert_vmaf(vmaf_params)

      # Should calculate 60% savings: (100-40)/100 * 1GB = 600MB
      assert vmaf.savings == 600_000_000
      assert vmaf.percent == 40
      assert vmaf.video_id == video.id
    end

    test "uses provided savings if given", %{video: video} do
      explicit_savings = 750_000_000

      vmaf_params = %{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.5",
        "percent" => "40",
        "savings" => explicit_savings,
        "params" => ["--preset", "medium"],
        "chosen" => false,
        "target" => 95
      }

      assert {:ok, vmaf} = Media.upsert_vmaf(vmaf_params)

      # Should use the explicitly provided savings, not calculate from percent
      assert vmaf.savings == explicit_savings
    end
  end
end
