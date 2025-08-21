defmodule Reencodarr.Encoder.Preset6EncodingTest do
  @moduledoc """
  Tests to ensure that when a video is retried with --preset 6,
  the encoder will actually use that parameter during encoding.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.Encoder.Broadway
  alias Reencodarr.Media

  describe "encoder uses preset 6 from VMAF params" do
    setup do
      video = Fixtures.video_fixture(%{path: "/test/video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "Encode module includes --preset 6 from VMAF params", %{video: video} do
      # Create a VMAF record with --preset 6 (as would be created by retry)
      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          chosen: true,
          params: ["--preset", "6", "--threads", "4"]
        })

      # Preload the video association for the encoder
      vmaf = Reencodarr.Repo.preload(vmaf, :video)

      # Get the build args (we can't actually run encode in tests)
      args = Encode.build_encode_args_for_test(vmaf)

      # Should include the preset 6 parameter
      assert "--preset" in args
      preset_index = Enum.find_index(args, &(&1 == "--preset"))
      assert Enum.at(args, preset_index + 1) == "6"

      # Should also include other VMAF params
      assert "--threads" in args
      threads_index = Enum.find_index(args, &(&1 == "--threads"))
      assert Enum.at(args, threads_index + 1) == "4"
    end

    test "Broadway encoder includes --preset 6 from VMAF params", %{video: video} do
      # Create a VMAF record with --preset 6 (as would be created by retry)
      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          chosen: true,
          params: ["--preset", "6", "--cpu-used", "8"]
        })

      # Preload the video association for the encoder
      vmaf = Reencodarr.Repo.preload(vmaf, :video)

      # Get the build args (we can't actually run encode in tests)
      args = Broadway.build_encode_args_for_test(vmaf)

      # Should include the preset 6 parameter
      assert "--preset" in args
      preset_index = Enum.find_index(args, &(&1 == "--preset"))
      assert Enum.at(args, preset_index + 1) == "6"

      # Should also include other VMAF params
      assert "--cpu-used" in args
      cpu_index = Enum.find_index(args, &(&1 == "--cpu-used"))
      assert Enum.at(args, cpu_index + 1) == "8"
    end

    test "VMAF params take precedence over rules when duplicated", %{video: video} do
      # Create a VMAF record with --preset 6
      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          chosen: true,
          params: ["--preset", "6"]
        })

      # Preload the video association for the encoder
      vmaf = Reencodarr.Repo.preload(vmaf, :video)

      args = Encode.build_encode_args_for_test(vmaf)

      # Should only have one --preset argument (the VMAF one should win)
      preset_occurrences = Enum.count(args, &(&1 == "--preset"))
      assert preset_occurrences == 1

      # The value should be "6" from VMAF params, not from rules
      preset_index = Enum.find_index(args, &(&1 == "--preset"))
      assert Enum.at(args, preset_index + 1) == "6"
    end

    test "handles VMAF with empty params gracefully", %{video: video} do
      # Create a VMAF record with empty params
      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 91.33,
          chosen: true,
          params: []
        })

      # Preload the video association for the encoder
      vmaf = Reencodarr.Repo.preload(vmaf, :video)

      # Should not crash and should still build valid args
      args = Encode.build_encode_args_for_test(vmaf)

      # Should have basic encode args
      assert "encode" in args
      assert "--crf" in args
      assert "28.0" in args
    end
  end
end
