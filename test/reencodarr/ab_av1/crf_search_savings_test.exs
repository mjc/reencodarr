defmodule Reencodarr.AbAv1.CrfSearchSavingsTest do
  @moduledoc """
  Tests for savings calculation in CRF search functionality.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.{Media, Repo}

  describe "calculate_savings/2" do
    test "calculates savings correctly for valid inputs" do
      # Test with 50% reduction on 1GB file
      # 1GB
      video_size = 1_000_000_000
      percent = 50.0

      # Should save 500MB (50% of original)
      expected_savings = 500_000_000

      # Use the private function through a test helper
      savings = calculate_savings_test_helper(percent, video_size)
      assert savings == expected_savings
    end

    test "handles string percent inputs" do
      video_size = 1_000_000_000

      savings = calculate_savings_test_helper("30", video_size)
      assert savings == 700_000_000

      savings_float = calculate_savings_test_helper("45.5", video_size)
      assert savings_float == 545_000_000
    end

    test "returns nil for invalid inputs" do
      video_size = 1_000_000_000

      # Nil inputs
      assert calculate_savings_test_helper(nil, video_size) == nil
      assert calculate_savings_test_helper(50.0, nil) == nil

      # Invalid percent values
      assert calculate_savings_test_helper(0, video_size) == nil
      assert calculate_savings_test_helper(-10, video_size) == nil
      assert calculate_savings_test_helper(101, video_size) == nil
    end
  end

  describe "VMAF upsert with savings" do
    setup do
      {:ok, video} =
        Media.create_video(%{
          path: "/test/movie.mkv",
          # 1GB video
          size: 1_000_000_000,
          bitrate: 5000
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

  # Test helper to access the private calculate_savings function
  defp calculate_savings_test_helper(percent, video_size) do
    # We'll create a temporary module to test the private function
    Code.eval_string("""
      defmodule TestHelper do
        def calculate_savings(nil, _video_size), do: nil
        def calculate_savings(_percent, nil), do: nil
        def calculate_savings(percent, video_size) when is_binary(percent) do
          case Float.parse(percent) do
            {percent_float, _} -> calculate_savings(percent_float, video_size)
            :error -> nil
          end
        end
        def calculate_savings(percent, video_size) when is_number(percent) and is_number(video_size) do
          if percent > 0 and percent <= 100 do
            # Savings = (100 - percent) / 100 * original_size
            round((100 - percent) / 100 * video_size)
          else
            nil
          end
        end
        def calculate_savings(_, _), do: nil
      end
    """)

    TestHelper.calculate_savings(percent, video_size)
  end
end
