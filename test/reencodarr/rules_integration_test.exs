defmodule Reencodarr.RulesIntegrationTest do
  use ExUnit.Case, async: true
  use Reencodarr.DataCase

  alias Reencodarr.AbAv1.{CrfSearch, Encode}
  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.{Media, Repo, Rules}

  describe "integration with encoder modules" do
    setup do
      {:ok, video} =
        Media.create_video(%{
          path: "/test/video#{System.unique_integer([:positive])}.mkv",
          title: "Test Video",
          size: 1_000_000,
          duration: 3600.0,
          width: 1920,
          # 1080p, not 4K
          height: 1080,
          frame_rate: 24.0,
          bitrate: 5_000_000,
          video_codecs: ["V_MPEGH/ISO/HEVC"],
          audio_codecs: ["A_EAC3"],
          max_audio_channels: 6,
          atmos: false,
          # Default to no HDR
          hdr: nil,
          state: :needs_analysis
        })

      %{video: video}
    end

    test "Broadway encoder includes audio arguments", %{video: video} do
      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 95.0,
          chosen: true,
          params: []
        })

      vmaf = Repo.preload(vmaf, :video)
      args = Encode.build_encode_args_for_test(vmaf)

      # Should include audio codec
      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "libopus"

      # Should include pixel format
      assert "--pix-format" in args
      pix_index = Enum.find_index(args, &(&1 == "--pix-format"))
      assert Enum.at(args, pix_index + 1) == "yuv420p10le"
    end

    test "Encode module includes audio arguments", %{video: video} do
      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 95.0,
          chosen: true,
          params: []
        })

      vmaf = Repo.preload(vmaf, :video)
      args = Encode.build_encode_args_for_test(vmaf)

      # Should include audio codec
      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "libopus"
    end

    test "CRF search excludes audio arguments", %{video: video} do
      args = CrfSearch.build_crf_search_args_for_test(video, 95)

      # Should NOT include audio codec
      refute "--acodec" in args

      # Should include video arguments
      assert "--pix-format" in args
      assert "--svt" in args
    end

    test "Rules.build_args includes video arguments for both contexts", %{video: video} do
      encode_args = Rules.build_args(video, :encode)
      crf_args = Rules.build_args(video, :crf_search)

      # Both should include pixel format
      assert "--pix-format" in encode_args
      assert "--pix-format" in crf_args

      encode_pix_index = Enum.find_index(encode_args, &(&1 == "--pix-format"))
      crf_pix_index = Enum.find_index(crf_args, &(&1 == "--pix-format"))

      assert Enum.at(encode_args, encode_pix_index + 1) == "yuv420p10le"
      assert Enum.at(crf_args, crf_pix_index + 1) == "yuv420p10le"

      # Both should include SVT arguments
      assert "--svt" in encode_args
      assert "--svt" in crf_args
    end

    test "Rules.build_args for CRF search excludes audio arguments", %{video: video} do
      args = Rules.build_args(video, :crf_search)

      # Should NOT include audio codec
      refute "--acodec" in args

      # Should NOT include audio enc arguments
      enc_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--enc" end)
        |> Enum.map(&elem(&1, 1))

      audio_enc_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "b:a=") or String.contains?(value, "ac=")
        end)

      refute audio_enc_found, "CRF search should not include audio enc arguments"
    end

    @tag :integration
    test "Encode module doesn't create duplicate input arguments" do
      # This tests the actual bug from the original error message
      # The issue is that Encode.build_encode_args combines base_args (with -i) and rule args (potentially with -i)

      # Create a VMAF record like the real system would have
      video =
        Fixtures.create_test_video(%{
          id: 8_443_455,
          path:
            "/mnt/tv/sci-fi/Fallout/Season 1/Fallout - S01E08 - The Beginning Bluray-2160p Remux DV HDR10 HEVC TrueHD Atmos 7.1.mkv",
          atmos: true,
          hdr: "HDR10"
        })

      # Simulate a VMAF record with params that might contain input arguments
      vmaf = %{
        id: 123,
        crf: 13.0,
        video: video,
        # This is the problem!
        params: ["-i", video.path, "--svt", "tune=0", "--svt", "dolbyvision=1"]
      }

      # Build the command like Encode module would
      encode_args = Encode.build_encode_args_for_test(vmaf)

      # Count how many times the input path appears
      input_path_count = Enum.count(encode_args, &(&1 == video.path))
      input_flag_count = Enum.count(encode_args, &(&1 == "--input"))

      IO.puts("\nInput path appears #{input_path_count} times")
      IO.puts("--input flag appears #{input_flag_count} times")

      # This should pass once we fix the deduplication
      assert input_path_count == 1, "Input path should appear only once, got #{input_path_count}"

      assert input_flag_count == 1,
             "--input flag should appear only once, got #{input_flag_count}"
    end
  end

  describe "ab-av1 integration tests" do
    @tag :integration
    test "generated arguments are accepted by ab-av1 --help" do
      video = Fixtures.create_test_video()

      # Test encode args
      encode_args = Rules.build_args(video, :encode, ["--preset", "6"])

      # Run ab-av1 with --help to validate argument structure
      # We prepend "encode --help" to check if the arguments would be valid
      test_args = ["encode", "--help"] ++ encode_args

      {output, exit_code} = System.cmd("ab-av1", test_args, stderr_to_stdout: true)

      # ab-av1 --help should exit with 0 and not complain about argument format
      assert exit_code == 0, "ab-av1 rejected arguments: #{output}"

      # Should not contain error messages about unexpected arguments
      refute String.contains?(output, "unexpected argument"),
             "ab-av1 found unexpected arguments: #{output}"

      refute String.contains?(output, "error:"),
             "ab-av1 error: #{output}"
    end

    @tag :integration
    test "generated CRF search arguments are accepted by ab-av1 --help" do
      video = Fixtures.create_test_video()

      # Test CRF search args using the CrfSearch module
      crf_args = CrfSearch.build_crf_search_args_for_test(video, 95)

      # Run ab-av1 with --help to validate argument structure
      # Remove "crf-search" since we're adding it
      test_args = ["crf-search", "--help"] ++ tl(crf_args)

      {output, exit_code} = System.cmd("ab-av1", test_args, stderr_to_stdout: true)

      # ab-av1 --help should exit with 0 and not complain about argument format
      assert exit_code == 0, "ab-av1 rejected CRF search arguments: #{output}"

      # Should not contain error messages about unexpected arguments
      refute String.contains?(output, "unexpected argument"),
             "ab-av1 found unexpected arguments in CRF search: #{output}"

      refute String.contains?(output, "error:"),
             "ab-av1 CRF search error: #{output}"
    end

    @tag :integration
    test "no duplicate input files in generated commands" do
      video = Fixtures.create_test_video(%{path: "/test/input.mkv"})

      # Test both encode and CRF search
      encode_args = Rules.build_args(video, :encode, ["--preset", "6"])
      crf_args = CrfSearch.build_crf_search_args_for_test(video, 95)

      # Count occurrences of the input file path
      input_count_encode = Enum.count(encode_args, &(&1 == video.path))
      input_count_crf = Enum.count(crf_args, &(&1 == video.path))

      # Should appear at most once in each command
      assert input_count_encode <= 1,
             "Input file appears #{input_count_encode} times in encode args: #{inspect(encode_args)}"

      assert input_count_crf <= 1,
             "Input file appears #{input_count_crf} times in CRF args: #{inspect(crf_args)}"
    end

    @tag :integration
    test "ab-av1 accepts generated encode command syntax" do
      # Simulate the problematic command from the error message
      video =
        Fixtures.create_test_video(%{
          path:
            "/mnt/tv/sci-fi/Fallout/Season 1/Fallout - S01E08 - The Beginning Bluray-2160p Remux DV HDR10 HEVC TrueHD Atmos 7.1.mkv",
          atmos: true,
          hdr: "HDR10"
        })

      # Build encode args like the real command would
      encode_args =
        Rules.build_args(video, :encode, ["--crf", "13.0", "-o", "/tmp/ab-av1/8443455.mkv"])

      # Check for duplicates of the long file path
      path_count = Enum.count(encode_args, &(&1 == video.path))
      assert path_count <= 1, "Input path appears #{path_count} times: #{inspect(encode_args)}"

      # Make sure the command structure is valid by testing with --help
      test_cmd = ["encode", "--help"] ++ encode_args
      {output, exit_code} = System.cmd("ab-av1", test_cmd, stderr_to_stdout: true)

      assert exit_code == 0, "ab-av1 rejected command structure: #{output}"
      refute String.contains?(output, "unexpected argument")
    end
  end
end
