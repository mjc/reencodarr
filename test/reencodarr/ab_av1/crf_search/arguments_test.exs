defmodule Reencodarr.AbAv1.CrfSearch.ArgumentsTest do
  @moduledoc """
  Tests for CRF search argument building and command construction.
  """
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.CrfSearch
  import Reencodarr.TestPatterns

  describe "build_crf_search_args_with_preset_6/2" do
    setup do
      video =
        create_test_video(%{
          path: "/test/args_video.mkv",
          size: 2_000_000_000,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      %{video: video}
    end

    test "includes basic CRF search arguments", %{video: video} do
      args = CrfSearch.build_crf_search_args_with_preset_6(video, 95)

      assert "crf-search" in args
      assert "--input" in args
      assert video.path in args
      assert "--min-vmaf" in args
      assert "95" in args
      assert "--temp-dir" in args
    end

    test "includes --preset 6 parameter", %{video: video} do
      args = CrfSearch.build_crf_search_args_with_preset_6(video, 95)

      preset_index = Enum.find_index(args, &(&1 == "--preset"))
      refute preset_index == nil
      assert Enum.at(args, preset_index + 1) == "6"
    end

    test "filters out audio-related arguments", %{video: video} do
      args = CrfSearch.build_crf_search_args_with_preset_6(video, 95)

      # Should not contain audio codec arguments
      refute "--acodec" in args

      # Should not contain audio bitrate arguments
      refute Enum.any?(args, &String.contains?(&1, "b:a="))

      # Should not contain audio channel arguments
      refute Enum.any?(args, &String.contains?(&1, "ac="))
    end

    test "includes video encoding rules", %{video: video} do
      args = CrfSearch.build_crf_search_args_with_preset_6(video, 95)

      # These should be included from Rules.apply/1 based on the video
      # The exact args depend on Rules implementation, so we just verify
      # that some rule-based args are present
      # More than just the basic args
      assert length(args) > 8
    end
  end

  describe "argument validation" do
    setup do
      video = create_test_video(%{path: "/test/validation_video.mkv", size: 1_000_000_000})
      %{video: video}
    end

    test "builds valid command arguments", %{video: video} do
      args = CrfSearch.build_crf_search_args_with_preset_6(video, 90)

      # Should have paired arguments (flag + value)
      flag_indices =
        args
        |> Enum.with_index()
        |> Enum.filter(fn {arg, _idx} -> String.starts_with?(arg, "--") end)
        |> Enum.map(fn {_arg, idx} -> idx end)

      # Each flag should have a value (except for boolean flags)
      Enum.each(flag_indices, fn flag_idx ->
        flag = Enum.at(args, flag_idx)

        # Skip boolean flags that don't need values
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
        args = CrfSearch.build_crf_search_args_with_preset_6(video, target)

        vmaf_index = Enum.find_index(args, &(&1 == "--min-vmaf"))
        assert Enum.at(args, vmaf_index + 1) == Integer.to_string(target)
      end
    end
  end
end
