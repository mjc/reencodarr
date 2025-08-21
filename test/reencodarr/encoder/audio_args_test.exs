defmodule Reencodarr.Encoder.AudioArgsTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Rules

  describe "centralized argument building" do
    setup do
      # Create a test video struct that represents a video needing audio transcoding (not Opus)
      video = Fixtures.create_test_video()
      %{video: video}
    end

    test "Rules.build_args for encoding includes audio arguments", %{video: video} do
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

    test "Rules.build_args handles additional params correctly", %{video: video} do
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

    test "Rules.build_args filters audio params from additional_params for CRF search", %{
      video: video
    } do
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

    test "Rules.build_args handles multiple SVT flags correctly" do
      # Create an HDR video using struct
      hdr_video = Fixtures.create_hdr_video()
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

  describe "legacy compatibility" do
    test "Rules.apply still works for backward compatibility" do
      video = Fixtures.create_test_video()
      rules = Rules.apply(video)

      # Should return tuples as before
      assert is_list(rules)
      assert Enum.all?(rules, fn item -> is_tuple(item) and tuple_size(item) == 2 end)

      # Find audio codec rule
      acodec_rule = Enum.find(rules, fn {flag, _} -> flag == "--acodec" end)
      assert acodec_rule == {"--acodec", "libopus"}

      # Find pixel format rule
      pix_rule = Enum.find(rules, fn {flag, _} -> flag == "--pix-format" end)
      assert pix_rule == {"--pix-format", "yuv420p10le"}
    end
  end
end
