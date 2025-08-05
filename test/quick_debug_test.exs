defmodule QuickDebugTest do
  use ExUnit.Case, async: true
  use Reencodarr.DataCase

  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.{Media, Repo}

  test "production scenario does not create duplicate paths" do
    # Create a video matching the production error
    {:ok, video} =
      Media.create_video(%{
        path:
          "/mnt/tv/sci-fi/Fallout/Season 1/Fallout - S01E08 - The Beginning Bluray-2160p Remux DV HDR10 HEVC TrueHD Atmos 7.1.mkv",
        title: "Test Video",
        size: 1_000_000,
        duration: 3600.0,
        width: 3840,
        height: 2160,
        frame_rate: 24.0,
        bitrate: 50_000_000,
        video_codecs: ["V_MPEGH/ISO/HEVC"],
        audio_codecs: ["A_TRUEHD"],
        max_audio_channels: 8,
        atmos: true,
        hdr: "HDR10",
        reencoded: false,
        failed: false
      })

    # Create VMAF with problematic params that include -i and -o
    {:ok, vmaf} =
      Media.create_vmaf(%{
        video_id: video.id,
        crf: 13.0,
        score: 95.0,
        chosen: true,
        params: [
          "-i",
          video.path,
          "-o",
          "/tmp/crf-output.mkv",
          "--svt",
          "tune=0",
          "--svt",
          "dolbyvision=1"
        ]
      })

    vmaf = Repo.preload(vmaf, :video)

    # Build the arguments like the production system would
    args = Encode.build_encode_args_for_test(vmaf)

    # Count how many times the path appears
    path_count = Enum.count(args, &(&1 == video.path))

    # Generate the command
    command = "ab-av1 " <> Enum.join(args, " ")
    require Logger
    Logger.debug(command)

    # This should pass with the fix
    assert path_count == 1, "Input path should appear only once, got #{path_count}"

    # Verify no standalone paths (paths that don't follow --input or --output)
    input_positions =
      args
      |> Enum.with_index()
      |> Enum.filter(fn {arg, _idx} -> arg == "--input" end)
      # Position of value after --input
      |> Enum.map(fn {_arg, idx} -> idx + 1 end)

    output_positions =
      args
      |> Enum.with_index()
      |> Enum.filter(fn {arg, _idx} -> arg == "--output" end)
      # Position of value after --output
      |> Enum.map(fn {_arg, idx} -> idx + 1 end)

    path_positions =
      args
      |> Enum.with_index()
      |> Enum.filter(fn {arg, _idx} -> arg == video.path end)
      |> Enum.map(fn {_arg, idx} -> idx end)

    # All path positions should be either after --input or --output
    valid_positions = input_positions ++ output_positions

    standalone_paths = path_positions -- valid_positions

    assert standalone_paths == [],
           "Found standalone paths at positions: #{inspect(standalone_paths)}"
  end
end
