defmodule Reencodarr.AbAv1.CrfSearch.RetryLogicTest do
  @moduledoc """
  Tests for CRF search retry logic with --preset 6 fallback.
  """
  use Reencodarr.DataCase, async: true
  import Ecto.Query

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  import Reencodarr.MediaFixtures

  describe "preset 6 retry decision logic" do
    setup do
      video = video_fixture(%{path: "/test/retry_video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "has_preset_6_params? correctly identifies preset 6", %{video: _video} do
      # Test the helper function that checks for --preset 6 in params

      # Should detect --preset 6
      params_with_preset_6 = ["--preset", "6", "--other", "value"]
      assert CrfSearch.has_preset_6_params?(params_with_preset_6) == true

      # Should not detect other presets
      params_with_different_preset = ["--preset", "medium", "--other", "value"]
      assert CrfSearch.has_preset_6_params?(params_with_different_preset) == false

      # Should handle empty params
      assert CrfSearch.has_preset_6_params?([]) == false

      # Should handle non-list params
      assert CrfSearch.has_preset_6_params?("not a list") == false

      # Should handle params without --preset
      params_without_preset = ["--other", "value"]
      assert CrfSearch.has_preset_6_params?(params_without_preset) == false
    end

    test "build_crf_search_args_with_preset_6 includes preset 6 parameter", %{video: video} do
      args = CrfSearch.build_crf_search_args_with_preset_6(video, 95)

      # Should include --preset 6
      assert "--preset" in args
      preset_index = Enum.find_index(args, &(&1 == "--preset"))
      assert Enum.at(args, preset_index + 1) == "6"

      # Should include basic CRF search args
      assert "crf-search" in args
      assert video.path in args
      assert "--min-vmaf" in args
      assert "95" in args
    end

    test "should_retry_with_preset_6 returns correct decisions based on VMAF records", %{
      video: video
    } do
      # Test case 1: No VMAF records -> mark as failed
      result = CrfSearch.should_retry_with_preset_6(video.id)
      assert result == :mark_failed

      # Test case 2: VMAF record without --preset 6 -> retry
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          params: ["--preset", "medium"]
        })

      result = CrfSearch.should_retry_with_preset_6(video.id)
      assert match?({:retry, _existing_vmafs}, result)

      # Test case 3: VMAF record with --preset 6 -> already retried
      {:ok, _vmaf2} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 30.0,
          score: 89.5,
          params: ["--preset", "6"]
        })

      result = CrfSearch.should_retry_with_preset_6(video.id)
      assert result == :already_retried
    end

    test "clear_vmaf_records_for_video removes specified records", %{video: video} do
      # Create some VMAF records
      {:ok, vmaf1} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          params: ["--preset", "medium"]
        })

      {:ok, vmaf2} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 30.0,
          score: 89.5,
          params: ["--preset", "fast"]
        })

      # Verify they exist (scoped to this video)
      video_vmaf_count =
        Vmaf
        |> where([v], v.video_id == ^video.id)
        |> Repo.aggregate(:count, :id)

      assert video_vmaf_count == 2

      # Clear them
      vmaf_records = [%{id: vmaf1.id}, %{id: vmaf2.id}]
      CrfSearch.clear_vmaf_records_for_video(video.id, vmaf_records)

      # Verify they're gone (scoped to this video)
      video_vmaf_count_after =
        Vmaf
        |> where([v], v.video_id == ^video.id)
        |> Repo.aggregate(:count, :id)

      assert video_vmaf_count_after == 0
    end
  end
end
