defmodule Reencodarr.RulesTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Rules
  import Reencodarr.TestHelpers

  describe "build_args/4 - context-based argument building" do
    test "encoding context copies audio for non-Opus audio" do
      video = Fixtures.create_test_video()
      args = Rules.build_args(video, :encode)

      # Should include audio copy
      assert "--acodec" in args
      assert "copy" in args

      # Should include video arguments
      assert "--pix-format" in args
      assert "yuv420p10le" in args
      assert "--svt" in args
      assert "tune=0" in args
    end

    test "encoding context copies audio for Opus audio too" do
      video = Fixtures.create_opus_video()
      args = Rules.build_args(video, :encode)

      # Should include audio copy
      assert "--acodec" in args
      assert "copy" in args

      # Should still include video arguments
      assert "--pix-format" in args
      assert "yuv420p10le" in args
    end

    test "crf_search context excludes audio arguments" do
      video = Fixtures.create_test_video()
      args = Rules.build_args(video, :crf_search)

      # Should NOT include audio arguments
      refute "--acodec" in args

      # Should include video arguments
      assert "--pix-format" in args
      assert "yuv420p10le" in args
      assert "--svt" in args
      assert "tune=0" in args
    end

    test "encoding context normalizes non-standard audio layouts with aformat filter" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          atmos: false,
          mediainfo: sample_mediainfo("AAC", 6, "5.1(side)")
        })

      args = Rules.build_args(video, :encode)

      assert "--acodec" in args
      acodec_index = Enum.find_index(args, &(&1 == "--acodec"))
      assert Enum.at(args, acodec_index + 1) == "copy"

      assert find_flag_value(args, "--enc", "c:a:0=libopus")
      assert find_flag_value(args, "--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo")
      refute find_flag_value(args, "--enc", "ac=6")
      refute find_flag_value(args, "--enc", "mapping_family=255")
    end
  end

  describe "build_args/4 - video-specific rules" do
    test "DV video includes dolbyvision enc flag" do
      video = Fixtures.create_hdr_video(%{hdr: "DV"})
      args = Rules.build_args(video, :encode)

      tune_found = find_flag_value(args, "--svt", "tune=0")
      dv_found = find_flag_value(args, "--enc", "dolbyvision=1")

      assert tune_found
      assert dv_found
    end

    test "HDR10 video does not include dolbyvision flag" do
      video = Fixtures.create_hdr_video(%{hdr: "HDR10"})
      args = Rules.build_args(video, :encode)

      tune_found = find_flag_value(args, "--svt", "tune=0")
      dv_found = find_flag_value(args, "--svt", "dolbyvision=1")

      assert tune_found
      refute dv_found
    end

    test "high resolution video includes scaling filter" do
      video = Fixtures.create_4k_video()
      args = Rules.build_args(video, :encode)

      # Should include scaling filter
      assert "--vfilter" in args
      vfilter_index = Enum.find_index(args, &(&1 == "--vfilter"))
      assert Enum.at(args, vfilter_index + 1) == "scale=1920:-2"
    end

    test "3-channel audio is copied (no upmix)" do
      video = Fixtures.create_test_video(%{max_audio_channels: 3})
      args = Rules.build_args(video, :encode)

      # Should copy audio
      assert "--acodec" in args
      assert "copy" in args
    end

    test "Atmos audio is copied" do
      video = Fixtures.create_test_video(%{atmos: true})
      args = Rules.build_args(video, :encode)

      # Should copy audio
      assert "--acodec" in args
      assert "copy" in args

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
      # Use non-Atmos DV video so audio rules apply and dolbyvision is included
      video = Fixtures.create_hdr_video(%{atmos: false, hdr: "DV"})
      additional_params = ["--svt", "extra=param", "--enc", "custom=setting"]
      args = Rules.build_args(video, :encode, additional_params)

      # Should have multiple SVT flags (extra + tune=0)
      svt_indices = find_flag_indices(args, "--svt")
      assert Enum.count(svt_indices) >= 2

      # Should have ENC flags: custom=setting from additional + dolbyvision=1 from DV rule
      enc_indices = find_flag_indices(args, "--enc")
      assert Enum.count(enc_indices) >= 2
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
        "copy",
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
        "copy"
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

  describe "individual rule functions" do
    test "audio/1 copies audio when metadata is not trustworthy enough to rule out Atmos" do
      video = Fixtures.create_test_video()
      rules = Rules.audio(video)

      assert rules == [{"--acodec", "copy"}]
    end

    test "audio/1 with Opus codec returns copy" do
      video = Fixtures.create_opus_video()
      rules = Rules.audio(video)
      assert rules == [{"--acodec", "copy"}]
    end

    test "audio/1 copies all audio when all tracks are Atmos" do
      video =
        raw_audio_video(
          ["truehd"],
          sample_mediainfo("Dolby TrueHD", 8, "7.1", %{
            "Format_Commercial_IfAny" => "Dolby TrueHD Atmos"
          })
        )

      assert Rules.audio(video) == [{"--acodec", "copy"}]
    end

    test "audio/1 with trusted non-atmos 5.1(side) normalizes layout with aformat filter" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1(side)")
        })

      rules = Rules.audio(video)

      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
      refute {"--enc", "ac=6"} in rules
      refute {"--enc", "mapping_family=255"} in rules
    end

    test "audio/1 with trusted non-atmos canonical 5.1 uses opus without layout normalization" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["aac"],
          mediainfo: sample_mediainfo("AAC", 6, "5.1")
        })

      rules = Rules.audio(video)

      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      refute {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
      refute {"--enc", "ac=6"} in rules
    end

    test "audio/1 transcodes eac3 to opus when no Atmos markers present" do
      video =
        Fixtures.create_test_video(%{
          audio_codecs: ["eac3"],
          mediainfo: sample_mediainfo("E-AC-3", 6, "5.1(side)")
        })

      rules = Rules.audio(video)
      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
      assert {"--enc", "filter:a:0=aformat=channel_layouts=5.1|7.1|stereo"} in rules
    end

    test "audio/1 copies tracks when raw CodecID shows E-AC-3 JOC (explicit Atmos marker)" do
      video =
        raw_audio_video(
          ["aac"],
          sample_mediainfo("Dolby Digital Plus", 6, "5.1(side)", %{
            "CodecID" => "A_EAC3/JOC",
            "Format_AdditionalFeatures" => "JOC"
          })
        )

      assert Rules.audio(video) == [{"--acodec", "copy"}]
    end

    test "audio/1 transcodes TrueHD to opus when no Atmos markers present" do
      video =
        raw_audio_video(
          ["aac"],
          sample_mediainfo("MLP FBA", 6, "5.1", %{"CodecID" => "A_TRUEHD"})
        )

      rules = Rules.audio(video)
      assert {"--acodec", "copy"} in rules
      assert {"--enc", "c:a:0=libopus"} in rules
    end

    test "hdr/2 with DV video includes dolbyvision enc flag (stock encoder)" do
      video = Fixtures.create_hdr_video(%{hdr: "DV"})
      rules = Rules.hdr(video, false)

      assert rules == [{"--enc", "dolbyvision=1"}]
    end

    test "hdr/2 with HDR10 video returns empty list (stock encoder)" do
      video = Fixtures.create_hdr_video()
      rules = Rules.hdr(video, false)

      assert rules == []
    end

    test "hdr/2 with non-HDR video returns empty list" do
      # Default is no HDR
      video = Fixtures.create_test_video()
      rules = Rules.hdr(video, false)

      assert rules == []
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
      additional_params = ["--preset", "6", "--acodec", "copy", "--enc", "ac=6"]

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
      assert Enum.at(args, acodec_index + 1) == "copy"
    end

    test "Rules.build_args handles multiple SVT/ENC flags correctly with DV" do
      # Use a simple struct with DV HDR
      dv_video = %Reencodarr.Media.Video{
        atmos: false,
        max_audio_channels: 6,
        audio_codecs: ["A_EAC3"],
        height: 1080,
        hdr: "DV"
      }

      args = Rules.build_args(dv_video, :encode)

      # tune=0 comes through --svt
      tune_found = find_flag_value(args, "--svt", "tune=0")
      assert tune_found, "Should include tune=0 for DV"

      # dolbyvision=1 is a libsvtav1 AVOption routed through --enc
      dv_found = find_flag_value(args, "--enc", "dolbyvision=1")
      assert dv_found, "Should include dolbyvision=1 via --enc for DV"
    end

    test "Rules.build_args does not include dolbyvision for HDR10" do
      hdr10_video = %Reencodarr.Media.Video{
        atmos: false,
        max_audio_channels: 6,
        audio_codecs: ["A_EAC3"],
        height: 1080,
        hdr: "HDR10"
      }

      args = Rules.build_args(hdr10_video, :encode)

      tune_found =
        Enum.chunk_every(args, 2, 1)
        |> Enum.any?(fn
          ["--svt", "tune=0"] -> true
          _ -> false
        end)

      dv_found =
        Enum.chunk_every(args, 2, 1)
        |> Enum.any?(fn
          ["--svt", "dolbyvision=1"] -> true
          _ -> false
        end)

      assert tune_found, "Should include tune=0 for HDR10"
      refute dv_found, "Should NOT include dolbyvision=1 for HDR10"
    end
  end

  describe "build_args/3 edge cases" do
    test "handles nil additional_params" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.build_args(video, :encode, nil)

      assert is_list(result)
      assert not Enum.empty?(result)
    end

    test "handles empty additional_params" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.build_args(video, :encode, [])

      assert is_list(result)
      assert not Enum.empty?(result)
    end

    test "handles malformed additional_params gracefully" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})

      # Single flag without value should be ignored
      result = Rules.build_args(video, :encode, ["--cpu-used"])

      assert is_list(result)
      # Should contain base rules but not the malformed flag
      refute "--cpu-used" in result
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
    test "high channel count still copies audio" do
      video = Fixtures.create_test_video(%{max_audio_channels: 15, audio_codecs: ["DTS"]})
      result = Rules.build_args(video, :encode)

      assert "--acodec" in result
      acodec_index = Enum.find_index(result, &(&1 == "--acodec"))
      assert Enum.at(result, acodec_index + 1) == "copy"
    end

    test "cuda function" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.cuda(video)

      assert result == [{"--enc-input", "hwaccel=cuda"}]
    end
  end

  describe "vintage content grain detection" do
    test "applies grain for content from before 2009 with (year) pattern" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/The Dark Knight (2008)/movie.mkv",
          title: "The Dark Knight"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "applies grain for content from before 2009 with [year] pattern" do
      video =
        Fixtures.create_test_video(%{
          path: "/tv/Lost [2004]/Season 1/episode.mkv",
          title: "Lost"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "applies grain for content from before 2009 with .year. pattern" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Casino.2005.BluRay.1080p.mkv",
          title: "Casino"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "applies grain for vintage content from title when path has no year" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/classic_movie.mkv",
          title: "Apocalypse Now (1979)"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "does not apply grain for content from 2009 or later" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Avatar (2009)/movie.mkv",
          title: "Avatar"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == []
    end

    test "does not apply grain for recent content" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Dune (2021)/movie.mkv",
          title: "Dune"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == []
    end

    test "applies grain for HDR content if vintage" do
      video =
        Fixtures.create_hdr_video(%{
          path: "/movies/Blade Runner (2007)/movie.mkv",
          title: "Blade Runner"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "does not apply grain when no year pattern is found" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/unknown_movie/file.mkv",
          title: "Unknown Movie"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == []
    end

    test "ignores false positive years outside valid range" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/High_Res_1080p/movie.mkv",
          title: "Some Movie"
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == []
    end

    test "uses most specific year pattern when multiple years present" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Remake (2010) of Classic (1985)/movie.mkv",
          title: "Movie Remake"
        })

      # Should pick (2010) over (1985) since (year) pattern comes first in regex list
      result = Rules.grain_for_vintage_content(video, false)

      assert result == []
    end

    test "grain detection is integrated into build_args pipeline" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/The Godfather (1972)/movie.mkv",
          title: "The Godfather"
        })

      args = Rules.build_args(video, :encode)

      # Should include grain arguments in the final build
      assert "--svt" in args
      assert "film-grain=8" in args
    end

    # API-based grain detection tests
    test "applies grain for vintage content using API content_year field" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/some_movie.mkv",
          title: "Classic Movie",
          content_year: 2005
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "does not apply grain for modern content using API content_year field" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/modern_movie.mkv",
          title: "Modern Movie",
          content_year: 2015
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == []
    end

    test "prefers API content_year over filename parsing" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Wrong Title (2020)/movie.mkv",
          title: "Classic Movie",
          # API says vintage, filename says modern
          content_year: 2005
        })

      result = Rules.grain_for_vintage_content(video, false)

      # Should use API year (2005) not filename year (2020)
      assert result == [{"--svt", "film-grain=8"}]
    end

    test "falls back to filename parsing when API content_year is nil" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Classic Movie (2005)/movie.mkv",
          title: "Classic Movie",
          # No API data, should parse filename
          content_year: nil
        })

      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
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

  describe "grain_for_vintage_content/1 - full coverage" do
    test "applies grain for API-sourced vintage content (2008)" do
      video = Fixtures.create_test_video(%{content_year: 2008, hdr: nil})
      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "applies grain for filename-parsed vintage content" do
      video =
        Fixtures.create_test_video(%{
          path: "/media/movies/Old.Movie.2005.mkv",
          title: "Old Movie",
          content_year: nil,
          hdr: nil
        })

      result = Rules.grain_for_vintage_content(video, false)
      assert result == [{"--svt", "film-grain=8"}]
    end

    test "skips grain for modern content (2010+)" do
      video = Fixtures.create_test_video(%{content_year: 2010, hdr: nil})
      result = Rules.grain_for_vintage_content(video, false)

      assert result == []
    end

    test "applies grain for HDR vintage content" do
      video = Fixtures.create_test_video(%{content_year: 2005, hdr: "HDR10"})
      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "skips grain when no year detected" do
      video =
        Fixtures.create_test_video(%{
          path: "/media/movies/NoYear.mkv",
          title: "No Year",
          content_year: nil,
          hdr: nil
        })

      result = Rules.grain_for_vintage_content(video, false)
      assert result == []
    end
  end

  describe "grain_for_vintage_content/2 - hdr fork behavior" do
    test "hdr fork: standard bitrate vintage returns strength 12 with denoise flags" do
      video = Fixtures.create_test_video(%{content_year: 2000, bitrate: 5_000_000})
      result = Rules.grain_for_vintage_content(video, true)

      assert {"--svt", "film-grain=12"} in result
      assert {"--svt", "film-grain-denoise=1"} in result
      assert {"--svt", "adaptive-film-grain=1"} in result
    end

    test "hdr fork: high bitrate (≥20Mbps) vintage returns strength 20 with denoise flags" do
      video = Fixtures.create_test_video(%{content_year: 2000, bitrate: 25_000_000})
      result = Rules.grain_for_vintage_content(video, true)

      assert {"--svt", "film-grain=20"} in result
      assert {"--svt", "film-grain-denoise=1"} in result
      assert {"--svt", "adaptive-film-grain=1"} in result
    end

    test "hdr fork: exactly at high bitrate threshold returns strength 20" do
      video = Fixtures.create_test_video(%{content_year: 2000, bitrate: 20_000_000})
      result = Rules.grain_for_vintage_content(video, true)

      assert {"--svt", "film-grain=20"} in result
    end

    test "stock encoder: always returns strength 8, no denoise flags" do
      video = Fixtures.create_test_video(%{content_year: 2000, bitrate: 25_000_000})
      result = Rules.grain_for_vintage_content(video, false)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "hdr fork: modern content returns empty list" do
      video = Fixtures.create_test_video(%{content_year: 2020})
      assert Rules.grain_for_vintage_content(video, true) == []
    end

    test "hdr fork: grain detected from path also includes denoise flags" do
      video =
        Fixtures.create_test_video(%{
          content_year: nil,
          path: "/movies/Alien (1979)/movie.mkv",
          bitrate: 5_000_000
        })

      result = Rules.grain_for_vintage_content(video, true)

      assert {"--svt", "film-grain=12"} in result
      assert {"--svt", "film-grain-denoise=1"} in result
      assert {"--svt", "adaptive-film-grain=1"} in result
    end
  end

  describe "cuda/1" do
    test "returns CUDA hardware acceleration config" do
      result = Rules.cuda(%{})

      assert result == [{"--enc-input", "hwaccel=cuda"}]
    end
  end

  describe "hdr/2" do
    test "DV always returns dolbyvision=1 via --enc regardless of hdr_fork" do
      video = Fixtures.create_test_video(%{hdr: "DV"})

      assert Rules.hdr(video, false) == [{"--enc", "dolbyvision=1"}]
      assert Rules.hdr(video, true) == [{"--enc", "dolbyvision=1"}]
    end

    test "HDR10 returns variance-boost-curve=3 with hdr fork" do
      video = Fixtures.create_test_video(%{hdr: "HDR10"})
      result = Rules.hdr(video, true)

      assert result == [{"--svt", "variance-boost-curve=3"}]
    end

    test "HDR10+ returns variance-boost-curve=3 with hdr fork" do
      video = Fixtures.create_test_video(%{hdr: "HDR10+"})
      result = Rules.hdr(video, true)

      assert result == [{"--svt", "variance-boost-curve=3"}]
    end

    test "HDR10 returns empty list with stock encoder" do
      video = Fixtures.create_test_video(%{hdr: "HDR10"})

      assert Rules.hdr(video, false) == []
    end

    test "HLG returns empty list with hdr fork (not a PQ transfer function)" do
      video = Fixtures.create_test_video(%{hdr: "HLG"})

      assert Rules.hdr(video, true) == []
    end

    test "HLG returns empty list with stock encoder" do
      video = Fixtures.create_test_video(%{hdr: "HLG"})

      assert Rules.hdr(video, false) == []
    end

    test "non-HDR returns empty list regardless of hdr_fork" do
      video = Fixtures.create_test_video(%{hdr: nil})

      assert Rules.hdr(video, false) == []
      assert Rules.hdr(video, true) == []
    end
  end

  describe "tune/2" do
    test "stock encoder always returns tune=0" do
      for year <- [1999, 2008, 2010, 2020] do
        video = Fixtures.create_test_video(%{content_year: year})
        assert Rules.tune(video, false) == [{"--svt", "tune=0"}]
      end
    end

    test "hdr fork returns tune=5 for vintage content" do
      video = Fixtures.create_test_video(%{content_year: 1999})
      assert Rules.tune(video, true) == [{"--svt", "tune=5"}]
    end

    test "hdr fork returns tune=5 for vintage content at boundary (2008)" do
      video = Fixtures.create_test_video(%{content_year: 2008})
      assert Rules.tune(video, true) == [{"--svt", "tune=5"}]
    end

    test "hdr fork returns tune=2 for modern content (2009+)" do
      video = Fixtures.create_test_video(%{content_year: 2009})
      assert Rules.tune(video, true) == [{"--svt", "tune=2"}]
    end

    test "hdr fork returns tune=2 for recent content" do
      video = Fixtures.create_test_video(%{content_year: 2020})
      assert Rules.tune(video, true) == [{"--svt", "tune=2"}]
    end

    test "hdr fork returns tune=2 for non-HDR content without year" do
      video = Fixtures.create_test_video(%{content_year: nil, path: "/movies/unknown.mkv"})
      assert Rules.tune(video, true) == [{"--svt", "tune=2"}]
    end

    test "hdr fork returns tune=5 for vintage content detected from path" do
      video =
        Fixtures.create_test_video(%{
          content_year: nil,
          path: "/movies/Blade Runner (1982)/movie.mkv"
        })

      assert Rules.tune(video, true) == [{"--svt", "tune=5"}]
    end
  end

  describe "resolution/1" do
    test "downscales 4K content (≥2160p)" do
      video = Fixtures.create_test_video(%{height: 2160})
      result = Rules.resolution(video)

      assert result == [{"--vfilter", "scale=1920:-2"}]
    end

    test "does not downscale 1440p content" do
      video = Fixtures.create_test_video(%{height: 1440})
      result = Rules.resolution(video)

      assert result == []
    end

    test "does not downscale 1080p content" do
      video = Fixtures.create_test_video(%{height: 1080})
      result = Rules.resolution(video)

      assert result == []
    end

    test "does not downscale lower resolution content" do
      video = Fixtures.create_test_video(%{height: 720})
      result = Rules.resolution(video)

      assert result == []
    end
  end

  describe "encoder/1" do
    test "always returns svt-av1 encoder" do
      video = Fixtures.create_test_video()
      result = Rules.encoder(video)

      assert result == [{"--encoder", "svt-av1"}]
    end
  end

  describe "preset/1" do
    test "returns preset 4 for 1080p content" do
      video = Fixtures.create_test_video(%{height: 1080})
      result = Rules.preset(video)

      assert result == [{"--preset", "4"}]
    end

    test "returns preset 4 for 4K content" do
      video = Fixtures.create_test_video(%{height: 2160})
      result = Rules.preset(video)

      assert result == [{"--preset", "4"}]
    end

    test "returns preset 6 for 720p content" do
      video = Fixtures.create_test_video(%{height: 720})
      result = Rules.preset(video)

      assert result == [{"--preset", "6"}]
    end

    test "returns preset 6 for 480p content" do
      video = Fixtures.create_test_video(%{height: 480})
      result = Rules.preset(video)

      assert result == [{"--preset", "6"}]
    end
  end

  describe "video/1" do
    test "returns pixel format configuration" do
      video = Fixtures.create_test_video()
      result = Rules.video(video)

      assert result == [{"--pix-format", "yuv420p10le"}]
    end
  end

  describe "extract_year_from_text/1" do
    test "extracts year from parentheses" do
      assert Rules.extract_year_from_text("Movie (2020) HD") == 2020
    end

    test "extracts year from filename pattern" do
      assert Rules.extract_year_from_text("/path/Show.S01E01.2015.mkv") == 2015
    end

    test "returns nil when no year found" do
      assert Rules.extract_year_from_text("No year here") == nil
    end
  end

  describe "audio copy for all channel configs" do
    test "3-channel audio is copied" do
      video = Fixtures.create_test_video(%{max_audio_channels: 3})
      args = Rules.build_args(video, :encode)

      assert "--acodec" in args
      assert "copy" in args
    end

    test "5.1 audio is copied" do
      video = Fixtures.create_test_video(%{max_audio_channels: 6})
      args = Rules.build_args(video, :encode)

      assert "--acodec" in args
      assert "copy" in args
    end
  end

  describe "base_args integration" do
    test "merges base args with rule-generated args" do
      video = Fixtures.create_test_video()
      base_args = ["--preset", "6", "--cpu-used", "4"]
      result = Rules.build_args(video, :encode, [], base_args)

      assert "--preset" in result
      assert "6" in result
      assert "--cpu-used" in result
      assert "4" in result
    end

    test "deduplicates short and long flag forms" do
      video = Fixtures.create_test_video()
      # Base args use short form, additional use long form
      base_args = ["-i", "input.mkv"]
      additional = ["--input", "other.mkv"]
      result = Rules.build_args(video, :encode, additional, base_args)

      # Should normalize to canonical --input and keep first occurrence
      input_count = Enum.count(result, &(&1 == "--input"))
      assert input_count == 1
    end

    test "filters out standalone file paths from params" do
      video = Fixtures.create_test_video()
      # File paths shouldn't be treated as standalone args
      additional = ["--preset", "6", "/path/to/file.mkv"]
      result = Rules.build_args(video, :encode, additional)

      # Should include --preset and value, but skip the file path
      assert "--preset" in result
      assert "6" in result
      refute "/path/to/file.mkv" in result
    end

    test "preserves known subcommands" do
      video = Fixtures.create_test_video()
      base_args = ["encode", "-i", "input.mkv"]
      result = Rules.build_args(video, :encode, [], base_args)

      # Subcommand should be first
      assert List.first(result) == "encode"
    end

    test "filters out unknown standalone values" do
      video = Fixtures.create_test_video()
      # "random-value" is not a known subcommand and has no flag
      base_args = ["--preset", "6", "random-value"]
      result = Rules.build_args(video, :encode, [], base_args)

      # Should keep flag-value pairs but not unknown standalone
      assert "--preset" in result
      assert "6" in result
      refute "random-value" in result
    end

    test "handles single flags without values" do
      video = Fixtures.create_test_video()
      base_args = ["-i", "input.mkv", "-y"]
      result = Rules.build_args(video, :encode, [], base_args)

      # -y is a valid single flag (overwrite without asking)
      assert "--input" in result
      assert "input.mkv" in result
    end
  end

  describe "vmaf_target/1" do
    test "returns 91 for files larger than 60 GiB" do
      video = %{size: 91 * 1024 * 1024 * 1024}
      assert Rules.vmaf_target(video) == 91
    end

    test "returns 92 for files larger than 40 GiB" do
      video = %{size: 50 * 1024 * 1024 * 1024}
      assert Rules.vmaf_target(video) == 92
    end

    test "returns 94 for files larger than 25 GiB" do
      video = %{size: 35 * 1024 * 1024 * 1024}
      assert Rules.vmaf_target(video) == 94
    end

    test "returns 95 for files 25 GiB or smaller" do
      video = %{size: 20 * 1024 * 1024 * 1024}
      assert Rules.vmaf_target(video) == 95
    end

    test "returns 95 for files with no size" do
      video = %{size: nil}
      assert Rules.vmaf_target(video) == 95
    end

    test "returns 95 for videos without size field" do
      video = %{}
      assert Rules.vmaf_target(video) == 95
    end

    test "exact threshold at 60 GiB returns 92" do
      video = %{size: 60 * 1024 * 1024 * 1024}
      assert Rules.vmaf_target(video) == 92
    end

    test "exact threshold at 40 GiB returns 94" do
      video = %{size: 40 * 1024 * 1024 * 1024}
      assert Rules.vmaf_target(video) == 94
    end

    test "exact threshold at 25 GiB returns 95" do
      video = %{size: 25 * 1024 * 1024 * 1024}
      assert Rules.vmaf_target(video) == 95
    end
  end

  describe "min_vmaf_target/1" do
    test "returns 90 for files larger than 60 GiB" do
      video = %{size: 91 * 1024 * 1024 * 1024}
      assert Rules.min_vmaf_target(video) == 90
    end

    test "returns 90 for files larger than 40 GiB" do
      video = %{size: 50 * 1024 * 1024 * 1024}
      assert Rules.min_vmaf_target(video) == 90
    end

    test "returns 92 for files larger than 25 GiB" do
      video = %{size: 35 * 1024 * 1024 * 1024}
      assert Rules.min_vmaf_target(video) == 92
    end

    test "returns 93 for files 25 GiB or smaller" do
      video = %{size: 20 * 1024 * 1024 * 1024}
      assert Rules.min_vmaf_target(video) == 93
    end

    test "is up to 2 below vmaf_target with floor of 90" do
      for size <- [nil, 10, 30, 45, 65, 100] do
        gib = if size, do: size * 1024 * 1024 * 1024, else: nil
        video = %{size: gib}
        assert Rules.min_vmaf_target(video) == max(90, Rules.vmaf_target(video) - 2)
      end
    end
  end

  describe "parameter filtering by context" do
    test "crf_search context filters out audio params from additional_params" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      additional = ["--acodec", "copy", "--preset", "6"]
      result = Rules.build_args(video, :crf_search, additional)

      # Audio params should be filtered
      refute "--acodec" in result
      refute "copy" in result
      # Non-audio params should be preserved
      assert "--preset" in result
    end

    test "crf_search filters --enc with audio content" do
      video = Fixtures.create_test_video()
      additional = ["--enc", "b:a=256k", "--enc", "crf=30"]
      result = Rules.build_args(video, :crf_search, additional)

      # --enc with b:a= should be filtered
      refute Enum.any?(result, &String.contains?(&1, "b:a="))
      # Other --enc should be allowed
      # (Note: crf=30 might also be filtered depending on logic)
    end

    test "encode context filters out crf-search specific params" do
      video = Fixtures.create_test_video()
      additional = ["--min-crf", "20", "--max-crf", "35", "--preset", "6"]
      result = Rules.build_args(video, :encode, additional)

      # CRF range flags should be filtered
      refute "--min-crf" in result
      refute "--max-crf" in result
      # Other params should be preserved
      assert "--preset" in result
    end

    test "encode context filters --temp-dir" do
      video = Fixtures.create_test_video()
      additional = ["--temp-dir", "/tmp/test"]
      result = Rules.build_args(video, :encode, additional)

      refute "--temp-dir" in result
    end

    test "encode context filters VMAF params" do
      video = Fixtures.create_test_video()
      additional = ["--min-vmaf", "90", "--max-vmaf", "95"]
      result = Rules.build_args(video, :encode, additional)

      refute "--min-vmaf" in result
      refute "--max-vmaf" in result
    end
  end

  describe "parameter parsing helpers" do
    test "flag?/1 identifies long flags" do
      assert Rules.flag?("--preset")
      assert Rules.flag?("--svt")
      assert Rules.flag?("--min-crf")
    end

    test "flag?/1 identifies short flags" do
      assert Rules.flag?("-i")
      assert Rules.flag?("-v")
      assert Rules.flag?("-h")
    end

    test "flag?/1 rejects non-flags" do
      refute Rules.flag?("4")
      refute Rules.flag?("crf-search")
      refute Rules.flag?("encode")
      refute Rules.flag?("/path/to/file.mkv")
    end

    test "file_path?/1 identifies absolute paths with extensions" do
      assert Rules.file_path?("/path/to/video.mkv")
      assert Rules.file_path?("/tmp/test.mp4")
      assert Rules.file_path?("/media/movie.avi")
    end

    test "file_path?/1 rejects non-file-paths" do
      refute Rules.file_path?("--preset")
      refute Rules.file_path?("4")
      refute Rules.file_path?("crf-search")
      refute Rules.file_path?("/path/without/extension")
    end

    test "standalone_value?/1 identifies subcommands" do
      assert Rules.standalone_value?("crf-search")
      assert Rules.standalone_value?("encode")
    end

    test "standalone_value?/1 rejects flags and values" do
      refute Rules.standalone_value?("--preset")
      refute Rules.standalone_value?("/path/to/file.mkv")
      refute Rules.standalone_value?("4")
    end
  end

  defp sample_mediainfo(format, channels, layout, audio_overrides \\ %{}) do
    default_bitrate = default_audio_bitrate(format, channels)

    %{
      "media" => %{
        "track" => [
          %{"@type" => "General", "Duration" => "7200.0"},
          %{"@type" => "Video", "Format" => "AVC", "Width" => "1920", "Height" => "1080"},
          Map.merge(
            %{
              "@type" => "Audio",
              "Format" => format,
              "CodecID" => format,
              "Channels" => Integer.to_string(channels),
              "ChannelLayout" => layout,
              "BitRate" => default_bitrate,
              "Default" => "Yes"
            },
            audio_overrides
          )
        ]
      }
    }
  end

  defp default_audio_bitrate("AAC", 2), do: 128_000
  defp default_audio_bitrate("AAC", 6), do: 256_000
  defp default_audio_bitrate("AAC", 8), do: 384_000
  defp default_audio_bitrate("E-AC-3", 2), do: 192_000
  defp default_audio_bitrate("E-AC-3", 6), do: 384_000
  defp default_audio_bitrate("MP3", 2), do: 320_000
  defp default_audio_bitrate("Dolby Digital Plus", 6), do: 384_000
  defp default_audio_bitrate("MLP FBA", 6), do: 3_000_000
  defp default_audio_bitrate("Dolby TrueHD", 6), do: 3_000_000
  defp default_audio_bitrate(_, 2), do: 128_000
  defp default_audio_bitrate(_, 6), do: 384_000
  defp default_audio_bitrate(_, 8), do: 384_000
  defp default_audio_bitrate(_, _), do: 256_000

  defp raw_audio_video(audio_codecs, mediainfo) do
    struct(Reencodarr.Media.Video, %{
      audio_codecs: audio_codecs,
      max_audio_channels: 6,
      atmos: false,
      mediainfo: mediainfo
    })
  end
end
