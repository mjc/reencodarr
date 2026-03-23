defmodule Reencodarr.Encoder.AudioArgsIntegrationTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Rules

  describe "centralized argument building" do
    setup do
      video = Fixtures.create_test_video()
      %{video: video}
    end

    test "Rules.build_args for encoding copies audio", %{video: video} do
      args = Rules.build_args(video, :encode)

      # Should include audio codec set to copy
      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "copy"

      # Should NOT include audio encoding enc arguments
      enc_indices =
        Enum.with_index(args)
        |> Enum.filter(fn {arg, _} -> arg == "--enc" end)
        |> Enum.map(&elem(&1, 1))

      audio_enc_found =
        Enum.any?(enc_indices, fn idx ->
          value = Enum.at(args, idx + 1)
          String.contains?(value, "b:a=") or String.contains?(value, "ac=")
        end)

      refute audio_enc_found, "Should not include audio encoding arguments"
    end

    test "Rules.build_args for CRF search excludes audio arguments", %{video: video} do
      args = Rules.build_args(video, :crf_search)

      # Should NOT include audio codec
      refute "--acodec" in args
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
      additional_params = ["--preset", "6", "--acodec", "copy", "--enc", "ac=6"]

      args = Rules.build_args(video, :crf_search, additional_params)

      # Should include video params
      assert "--preset" in args

      # Should NOT include audio params from additional_params
      refute "--acodec" in args
    end

    test "Rules.build_args handles multiple SVT/ENC flags correctly with DV" do
      # dolbyvision is a libsvtav1 AVOption routed through --enc, not --svt
      dv_video = Fixtures.create_hdr_video(%{hdr: "DV"})
      args = Rules.build_args(dv_video, :encode)

      tune_found =
        Enum.chunk_every(args, 2, 1, :discard)
        |> Enum.any?(&(&1 == ["--svt", "tune=0"]))

      assert tune_found, "Should include tune=0 for DV"

      dv_found =
        Enum.chunk_every(args, 2, 1, :discard)
        |> Enum.any?(&(&1 == ["--enc", "dolbyvision=1"]))

      assert dv_found, "Should include dolbyvision=1 via --enc for DV"
    end
  end
end
