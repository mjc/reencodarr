defmodule Reencodarr.Encoder.AudioArgsTest do
  use Reencodarr.DataCase

  alias Reencodarr.AbAv1.{CrfSearch, Encode}
  alias Reencodarr.Encoder.Broadway
  alias Reencodarr.{Media, Repo, Rules}

  describe "centralized argument building" do
    setup do
      # Create a mediainfo structure that represents a video needing audio transcoding (not Opus)
      mediainfo = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "AudioCount" => "1",
              "OverallBitRate" => "25000000",
              "Duration" => "3600.0",
              "FileSize" => "1000000",
              "TextCount" => "0",
              "VideoCount" => "1",
              "Title" => "Test Video"
            },
            %{
              "@type" => "Video",
              "FrameRate" => "24.0",
              "Height" => "1080",
              "Width" => "1920",
              "CodecID" => "V_MPEGH/ISO/HEVC"
            },
            %{
              "@type" => "Audio",
              "CodecID" => "A_EAC3",
              "Channels" => "6",
              "Format_Commercial_IfAny" => "Dolby Digital Plus"
            }
          ]
        }
      }

      # Create a video that will get populated from mediainfo
      {:ok, video} =
        Media.create_video(%{
          path: "/test/centralized_args_video.mkv",
          size: 1_000_000,
          mediainfo: mediainfo
        })

      {:ok, vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 95.0,
          chosen: true,
          params: []
        })

      # Preload associations
      vmaf = Repo.preload(vmaf, :video)

      %{video: video, vmaf: vmaf}
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

    test "Rules.build_args handles multiple SVT flags correctly", %{video: _video} do
      # Create an HDR video using MediaInfo processing
      hdr_mediainfo = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "AudioCount" => "1",
              "OverallBitRate" => "25000000",
              "Duration" => "3600.0",
              "FileSize" => "1000000",
              "TextCount" => "0",
              "VideoCount" => "1",
              "Title" => "HDR Test Video"
            },
            %{
              "@type" => "Video",
              "FrameRate" => "24.0",
              "Height" => "1080",
              "Width" => "1920",
              "CodecID" => "V_MPEGH/ISO/HEVC",
              "HDR_Format" => "SMPTE ST 2086",
              "HDR_Format_Compatibility" => "HDR10"
            },
            %{
              "@type" => "Audio",
              "CodecID" => "A_EAC3",
              "Channels" => "6",
              "Format_Commercial_IfAny" => "Dolby Digital Plus"
            }
          ]
        }
      }

      {:ok, hdr_video} =
        Media.create_video(%{
          path: "/test/hdr_test_video.mkv",
          size: 1_000_000,
          mediainfo: hdr_mediainfo
        })

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

      # Clean up
      Media.delete_video(hdr_video)
    end
  end

  describe "encoder integration" do
    setup do
      # Use MediaInfo structure like the main tests
      mediainfo = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "AudioCount" => "1",
              "OverallBitRate" => "25000000",
              "Duration" => "3600.0",
              "FileSize" => "1000000",
              "TextCount" => "0",
              "VideoCount" => "1",
              "Title" => "Test Video"
            },
            %{
              "@type" => "Video",
              "FrameRate" => "24.0",
              "Height" => "1080",
              "Width" => "1920",
              "CodecID" => "V_MPEGH/ISO/HEVC"
            },
            %{
              "@type" => "Audio",
              "CodecID" => "A_EAC3",
              "Channels" => "6",
              "Format_Commercial_IfAny" => "Dolby Digital Plus"
            }
          ]
        }
      }

      {:ok, video} =
        Media.create_video(%{
          path: "/test/encoder_integration_video.mkv",
          size: 1_000_000,
          mediainfo: mediainfo
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
      args = Broadway.build_encode_args_for_test(vmaf)

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
  end

  describe "legacy compatibility" do
    test "Rules.apply still works for backward compatibility" do
      video = %Reencodarr.Media.Video{
        atmos: false,
        max_audio_channels: 6,
        audio_codecs: ["A_EAC3"],
        height: 1080,
        hdr: nil
      }

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
