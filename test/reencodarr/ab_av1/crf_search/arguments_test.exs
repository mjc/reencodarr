defmodule Reencodarr.AbAv1.CrfSearch.ArgumentsTest do
  @moduledoc """
  Pure unit tests for CRF search argument building and command construction.
  """
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.AbAv1.CrfSearch

  describe "build_crf_search_args/3 with crf_range option" do
    setup do
      alias Reencodarr.Media.Video

      video = %Video{
        id: 1,
        path: "/test/args_video.mkv",
        size: 2_000_000_000,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        width: 1920,
        height: 1080,
        bitrate: 8_000_000,
        duration: 7200.0,
        max_audio_channels: 6,
        atmos: false,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

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

      assert length(args) > 10
    end
  end

  describe "argument validation" do
    setup do
      alias Reencodarr.Media.Video

      video = %Video{
        id: 2,
        path: "/test/validation_video.mkv",
        size: 1_000_000_000,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        width: 1920,
        height: 1080,
        bitrate: 8_000_000,
        duration: 7200.0,
        max_audio_channels: 6,
        atmos: false,
        hdr: nil,
        service_id: "test",
        service_type: :sonarr
      }

      %{video: video}
    end

    test "builds valid command arguments with custom range", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 90, crf_range: {10, 35})

      assert is_list(args)
      assert Enum.all?(args, &is_binary/1)
      assert length(args) > 5
      assert length(args) < 100
    end

    test "handles different VMAF targets with custom range", %{video: video} do
      args_95 = CrfSearch.build_crf_search_args(video, 95, crf_range: {14, 30})
      args_90 = CrfSearch.build_crf_search_args(video, 90, crf_range: {14, 30})

      assert "95" in args_95
      assert "90" in args_90
      refute args_95 == args_90
    end
  end
end
