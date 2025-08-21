defmodule Reencodarr.RulesTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Rules
  import Reencodarr.TestHelpers

  describe "build_args/4 - context-based argument building" do
    test "encoding context includes audio arguments for non-Opus audio" do
      video = Fixtures.create_test_video()
      args = Rules.build_args(video, :encode)

      # Should include audio arguments
      assert "--acodec" in args
      assert "libopus" in args
      assert "--enc" in args
      assert "b:a=256k" in args
      assert "ac=6" in args

      # Should include video arguments
      assert "--pix-format" in args
      assert "yuv420p10le" in args
      assert "--svt" in args
      assert "tune=0" in args
    end

    test "encoding context skips audio arguments for Opus audio" do
      video = Fixtures.create_opus_video()
      args = Rules.build_args(video, :encode)

      # Should NOT include audio arguments (already Opus)
      refute "--acodec" in args
      refute "libopus" in args

      # Should still include video arguments
      assert "--pix-format" in args
      assert "yuv420p10le" in args
    end

    test "crf_search context excludes audio arguments" do
      video = Fixtures.create_test_video()
      args = Rules.build_args(video, :crf_search)

      # Should NOT include audio arguments
      refute "--acodec" in args
      refute "libopus" in args
      refute "b:a=256k" in args
      refute "ac=6" in args

      # Should include video arguments
      assert "--pix-format" in args
      assert "yuv420p10le" in args
      assert "--svt" in args
      assert "tune=0" in args
    end
  end

  describe "build_args/4 - video-specific rules" do
    test "HDR video includes multiple SVT flags" do
      video = Fixtures.create_hdr_video()
      args = Rules.build_args(video, :encode)

      # Should include both SVT flags
      tune_found = find_flag_value(args, "--svt", "tune=0")
      dv_found = find_flag_value(args, "--svt", "dolbyvision=1")

      assert tune_found
      assert dv_found
    end

    test "high resolution video includes scaling filter" do
      video = Fixtures.create_4k_video()
      args = Rules.build_args(video, :encode)

      # Should include scaling filter
      assert "--vfilter" in args
      vfilter_index = Enum.find_index(args, &(&1 == "--vfilter"))
      assert Enum.at(args, vfilter_index + 1) == "scale=1920:-2"
    end

    test "3-channel audio gets upmixed to 5.1" do
      video = Fixtures.create_test_video(%{max_audio_channels: 3})
      args = Rules.build_args(video, :encode)

      # Should include upmix settings
      assert "--acodec" in args
      assert "libopus" in args
      assert "b:a=128k" in args
      assert "ac=6" in args
    end

    test "Atmos audio is skipped" do
      video = Fixtures.create_test_video(%{atmos: true})
      args = Rules.build_args(video, :encode)

      # Should NOT include audio arguments
      refute "--acodec" in args
      refute "libopus" in args

      # Should still include video arguments
      assert "--pix-format" in args
      assert "--svt" in args
    end
  end

  describe "build_args/4 - additional parameters and precedence" do
    test "additional params are included and take precedence" do
      video = Fixtures.create_test_video()
      additional_params = ["--preset", "6", "--cpu-used", "8", "--svt", "custom=value"]
      args = Rules.build_args(video, :encode, additional_params)

      # Should include additional params
      assert_flag_value_present(args, "--preset", "6")
      assert_flag_value_present(args, "--cpu-used", "8")

      # Should include custom SVT param
      custom_svt_found = find_flag_value(args, "--svt", "custom=value")
      assert custom_svt_found

      # Should still include rule-based arguments
      assert "--acodec" in args
      assert "--pix-format" in args
    end

    test "duplicate flags are removed, keeping first occurrence" do
      video = Fixtures.create_test_video()
      # Additional params that conflict with rules (different from rule's yuv420p10le)
      additional_params = ["--pix-format", "yuv420p"]
      args = Rules.build_args(video, :encode, additional_params)

      # Should keep the additional param value (first occurrence)
      pix_indices = find_flag_indices(args, "--pix-format")
      # Should only appear once
      assert length(pix_indices) == 1

      pix_index = hd(pix_indices)
      # Additional param wins
      assert Enum.at(args, pix_index + 1) == "yuv420p"
    end

    test "multiple SVT and ENC flags are preserved" do
      # Use non-Atmos HDR video so audio rules apply
      video = Fixtures.create_hdr_video(%{atmos: false})
      additional_params = ["--svt", "extra=param", "--enc", "custom=setting"]
      args = Rules.build_args(video, :encode, additional_params)

      # Should have multiple SVT flags
      svt_indices = find_flag_indices(args, "--svt")
      # extra + tune=0 + dolbyvision=1
      assert length(svt_indices) >= 3

      # Should have multiple ENC flags
      enc_indices = find_flag_indices(args, "--enc")
      # custom + b:a= + ac=
      assert length(enc_indices) >= 3
    end
  end

  describe "build_args/4 - context filtering" do
    test "CRF search filters out audio params from additional_params" do
      video = Fixtures.create_test_video()

      additional_params = [
        "--preset",
        "6",
        # Should be filtered out
        "--acodec",
        "libopus",
        # Should be filtered out
        "--enc",
        "b:a=128k",
        # Should be filtered out
        "--enc",
        "ac=6",
        # Should be kept
        "--enc",
        "x265-params=crf=20"
      ]

      args = Rules.build_args(video, :crf_search, additional_params)

      # Should include video params
      assert "--preset" in args

      # Should NOT include audio params
      refute "--acodec" in args
      refute "b:a=128k" in args
      refute "ac=6" in args

      # Should include non-audio enc params
      assert "x265-params=crf=20" in args
    end

    test "encoding filters out CRF search specific params from additional_params" do
      video = Fixtures.create_test_video()

      additional_params = [
        "--preset",
        "6",
        # Should be filtered out
        "--temp-dir",
        "/tmp/test",
        # Should be filtered out
        "--min-vmaf",
        "95",
        # Should be kept
        "--acodec",
        "libopus"
      ]

      args = Rules.build_args(video, :encode, additional_params)

      # Should include encoding params
      assert "--preset" in args
      assert "--acodec" in args

      # Should NOT include CRF search specific params
      refute "--temp-dir" in args
      refute "--min-vmaf" in args
      refute "/tmp/test" in args
      refute "95" in args
    end
  end

  describe "build_args/4 - edge cases and error handling" do
    test "handles empty additional_params" do
      video = Fixtures.create_test_video()
      args = Rules.build_args(video, :encode, [])

      # Should include rule-based arguments
      assert "--acodec" in args
      assert "--pix-format" in args
      assert "--svt" in args
    end

    test "handles nil additional_params" do
      video = Fixtures.create_test_video()
      args = Rules.build_args(video, :encode, nil)

      # Should include rule-based arguments
      assert "--acodec" in args
      assert "--pix-format" in args
      assert "--svt" in args
    end

    test "handles malformed additional_params gracefully" do
      video = Fixtures.create_test_video()
      # Test with invalid param structure
      # Missing value for --incomplete
      malformed_params = ["--preset", "--incomplete"]

      # Should not crash and should include valid params
      args = Rules.build_args(video, :encode, malformed_params)

      assert "--preset" in args
      assert "--acodec" in args
      assert "--pix-format" in args
    end
  end

  describe "apply/1 (legacy compatibility)" do
    test "returns tuples for backward compatibility" do
      video = Fixtures.create_test_video()
      rules = Rules.apply(video)

      # Should return list of tuples
      assert is_list(rules)
      assert Enum.all?(rules, fn item -> is_tuple(item) and tuple_size(item) == 2 end)

      # Should include expected rules
      assert {"--acodec", "libopus"} in rules
      assert {"--pix-format", "yuv420p10le"} in rules
      assert {"--svt", "tune=0"} in rules
    end
  end

  describe "individual rule functions" do
    test "audio/1 with EAC3 codec" do
      video = Fixtures.create_test_video()
      rules = Rules.audio(video)

      assert {"--acodec", "libopus"} in rules
      assert {"--enc", "b:a=256k"} in rules
      assert {"--enc", "ac=6"} in rules
    end

    test "audio/1 with Opus codec returns empty" do
      video = Fixtures.create_opus_video()
      rules = Rules.audio(video)
      assert rules == []
    end

    test "audio/1 with Atmos returns empty" do
      video = Fixtures.create_test_video(%{atmos: true})
      rules = Rules.audio(video)
      assert rules == []
    end

    test "hdr/1 with HDR video" do
      video = Fixtures.create_hdr_video()
      rules = Rules.hdr(video)

      assert {"--svt", "tune=0"} in rules
      assert {"--svt", "dolbyvision=1"} in rules
      assert length(rules) == 2
    end

    test "hdr/1 with non-HDR video" do
      # Default is no HDR
      video = Fixtures.create_test_video()
      rules = Rules.hdr(video)

      assert rules == [{"--svt", "tune=0"}]
    end

    test "resolution/1 with 4K video" do
      video = Fixtures.create_4k_video()
      rules = Rules.resolution(video)

      assert rules == [{"--vfilter", "scale=1920:-2"}]
    end

    test "resolution/1 with 1080p video" do
      # Default is 1080p
      video = Fixtures.create_test_video()
      rules = Rules.resolution(video)

      assert rules == []
    end

    test "video/1 always returns pixel format" do
      video = Fixtures.create_test_video()
      rules = Rules.video(video)

      assert rules == [{"--pix-format", "yuv420p10le"}]
    end
  end

  describe "pure unit tests" do
    test "Rules.build_args handles additional params correctly" do
      # Use a simple struct instead of database video
      video = %Reencodarr.Media.Video{
        atmos: false,
        max_audio_channels: 6,
        audio_codecs: ["A_EAC3"],
        height: 1080,
        hdr: nil
      }

      additional_params = ["--preset", "6", "--cpu-used", "8"]

      args = Rules.build_args(video, :encode, additional_params)

      # Should include additional params
      assert "--preset" in args
      preset_index = Enum.find_index(args, &(&1 == "--preset"))
      assert Enum.at(args, preset_index + 1) == "6"

      assert "--cpu-used" in args
      cpu_index = Enum.find_index(args, &(&1 == "--cpu-used"))
      assert Enum.at(args, cpu_index + 1) == "8"

      # Should still include rule-based args
      assert "--pix-format" in args
      assert "--acodec" in args
    end

    test "Rules.build_args filters audio params from additional_params for CRF search" do
      video = Fixtures.create_test_video()
      additional_params = ["--preset", "6", "--acodec", "libopus", "--enc", "ac=6"]

      args = Rules.build_args(video, :crf_search, additional_params)

      # Should include video params
      assert "--preset" in args

      # Should NOT include audio params from additional_params
      refute "--acodec" in args

      # Check that audio enc param is filtered out
      enc_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--enc" end)
        |> Enum.map(&elem(&1, 1))

      audio_enc_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "ac=")
        end)

      refute audio_enc_found
    end

    test "Rules.build_args for encoding includes audio arguments" do
      # Use a simple struct instead of database video
      video = %Reencodarr.Media.Video{
        atmos: false,
        max_audio_channels: 6,
        audio_codecs: ["A_EAC3"],
        height: 1080,
        hdr: nil
      }

      args = Rules.build_args(video, :encode)

      # Should include audio codec
      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "libopus"

      # Should include audio bitrate
      enc_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--enc" end)
        |> Enum.map(&elem(&1, 1))

      bitrate_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "b:a=")
        end)

      assert bitrate_found, "Should include audio bitrate argument"

      # Should include audio channels
      channels_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "ac=")
        end)

      assert channels_found, "Should include audio channels argument"
    end

    test "Rules.build_args handles multiple SVT flags correctly with HDR" do
      # Use a simple struct with HDR
      hdr_video = %Reencodarr.Media.Video{
        atmos: false,
        max_audio_channels: 6,
        audio_codecs: ["A_EAC3"],
        height: 1080,
        hdr: "HDR10"
      }

      args = Rules.build_args(hdr_video, :encode)

      # Should include multiple SVT arguments
      svt_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--svt" end)
        |> Enum.map(&elem(&1, 1))

      # Should have at least tune=0 and dolbyvision=1
      tune_found =
        Enum.any?(svt_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          value == "tune=0"
        end)

      assert tune_found, "Should include tune=0 for HDR"

      dv_found =
        Enum.any?(svt_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          value == "dolbyvision=1"
        end)

      assert dv_found, "Should include dolbyvision=1 for HDR"
    end
  end

  describe "build_args/3 edge cases" do
    test "handles nil additional_params" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.build_args(video, :encode, nil)

      assert is_list(result)
      assert length(result) > 0
    end

    test "handles empty additional_params" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.build_args(video, :encode, [])

      assert is_list(result)
      assert length(result) > 0
    end

    test "handles malformed additional_params gracefully" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})

      # Single flag without value should be ignored
      result = Rules.build_args(video, :encode, ["--preset"])

      assert is_list(result)
      # Should contain base rules but not the malformed preset
      refute "--preset" in result
    end

    test "handles properly formed additional_params" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})

      # Test with properly formed arguments only
      result = Rules.build_args(video, :encode, ["--preset", "6", "--cpu-used", "8"])

      assert is_list(result)
      assert "--preset" in result
      assert "6" in result
      assert "--cpu-used" in result
      assert "8" in result

      # Should include basic video arguments
      assert "--pix-format" in result
      assert "--acodec" in result
    end
  end

  describe "uncovered function coverage" do
    test "opus_bitrate handles channels > 11" do
      video = Fixtures.create_test_video(%{max_audio_channels: 15, audio_codecs: ["DTS"]})
      result = Rules.build_args(video, :encode)

      # Should use max bitrate of 510k for very high channel counts
      assert "--enc" in result
      bitrate_index = Enum.find_index(result, &(&1 == "--enc")) + 1
      assert Enum.at(result, bitrate_index) == "b:a=510k"
    end

    test "cuda function" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.cuda(video)

      assert result == [{"--enc-input", "hwaccel=cuda"}]
    end

    test "grain function with non-HDR video" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.grain(video, 25)

      assert result == [{"--svt", "film-grain=25:film-grain-denoise=0"}]
    end

    test "grain function fallback clause" do
      hdr_video = Fixtures.create_hdr_video(%{max_audio_channels: 2})

      result = Rules.grain(hdr_video, 25)

      assert result == []
    end
  end

  describe "duplicate flag handling" do
    test "removes duplicate flags except svt and enc" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})

      # Test with duplicate --preset flags (should keep first)
      result = Rules.build_args(video, :encode, ["--preset", "6", "--preset", "8"])

      preset_count = Enum.count(result, &(&1 == "--preset"))
      assert preset_count == 1, "Should deduplicate --preset flags"

      preset_index = Enum.find_index(result, &(&1 == "--preset"))
      assert Enum.at(result, preset_index + 1) == "6", "Should keep first --preset value"
    end

    test "allows multiple svt and enc flags" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})

      # SVT and ENC flags should be allowed multiple times
      result = Rules.build_args(video, :encode, ["--svt", "tune=1", "--enc", "crf=30"])

      svt_count = Enum.count(result, &(&1 == "--svt"))
      enc_count = Enum.count(result, &(&1 == "--enc"))

      # Should have at least the additional ones plus any from rules
      assert svt_count >= 1
      assert enc_count >= 1
    end
  end
end
