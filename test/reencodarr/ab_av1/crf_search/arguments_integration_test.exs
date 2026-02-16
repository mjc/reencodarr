defmodule Reencodarr.AbAv1.CrfSearch.ArgumentsIntegrationTest do
  @moduledoc """
  Integration tests for CRF search argument building with database fixtures.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.CrfSearch

  describe "build_crf_search_args/3 with crf_range option" do
    setup do
      video =
        Fixtures.create_test_video(%{
          path: "/test/args_video.mkv",
          size: 2_000_000_000,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      %{video: video}
    end

    test "includes basic CRF search arguments", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {14, 30})

      assert "crf-search" in args
      assert "--input" in args
      assert video.path in args
      assert "--min-vmaf" in args
      assert "95" in args
      assert "--temp-dir" in args
    end

    test "uses provided CRF range", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {14, 30})

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))
      refute min_idx == nil
      refute max_idx == nil
      assert Enum.at(args, min_idx + 1) == "14"
      assert Enum.at(args, max_idx + 1) == "30"
    end

    test "filters out audio-related arguments", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {14, 30})

      refute "--acodec" in args
      refute Enum.any?(args, &String.contains?(&1, "b:a="))
      refute Enum.any?(args, &String.contains?(&1, "ac="))
    end

    test "includes video encoding rules", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {14, 30})

      # More than just the basic args
      assert length(args) > 8
    end
  end

  describe "argument validation" do
    setup do
      video =
        Fixtures.create_test_video(%{path: "/test/validation_video.mkv", size: 1_000_000_000})

      %{video: video}
    end

    test "builds valid command arguments with custom range", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 90, crf_range: {10, 35})

      flag_indices =
        args
        |> Enum.with_index()
        |> Enum.filter(fn {arg, _idx} -> String.starts_with?(arg, "--") end)
        |> Enum.map(fn {_arg, idx} -> idx end)

      Enum.each(flag_indices, fn flag_idx ->
        flag = Enum.at(args, flag_idx)
        boolean_flags = []

        if flag not in boolean_flags do
          value = Enum.at(args, flag_idx + 1)
          refute value == nil
          refute String.starts_with?(value, "--")
        end
      end)
    end

    test "handles different VMAF targets", %{video: video} do
      for target <- [85, 90, 95, 98] do
        args = CrfSearch.build_crf_search_args(video, target, crf_range: {14, 30})

        vmaf_index = Enum.find_index(args, &(&1 == "--min-vmaf"))
        assert Enum.at(args, vmaf_index + 1) == Integer.to_string(target)
      end
    end
  end
end
