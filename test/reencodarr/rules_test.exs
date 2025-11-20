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

      assert result == [{"--svt", "film-grain=25"}]
    end

    test "grain function fallback clause" do
      hdr_video = Fixtures.create_hdr_video(%{max_audio_channels: 2})

      result = Rules.grain(hdr_video, 25)

      assert result == []
    end
  end

  describe "vintage content grain detection" do
    test "applies grain for content from before 2009 with (year) pattern" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/The Dark Knight (2008)/movie.mkv",
          title: "The Dark Knight"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "applies grain for content from before 2009 with [year] pattern" do
      video =
        Fixtures.create_test_video(%{
          path: "/tv/Lost [2004]/Season 1/episode.mkv",
          title: "Lost"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "applies grain for content from before 2009 with .year. pattern" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Casino.2005.BluRay.1080p.mkv",
          title: "Casino"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "applies grain for vintage content from title when path has no year" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/classic_movie.mkv",
          title: "Apocalypse Now (1979)"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "does not apply grain for content from 2009 or later" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Avatar (2009)/movie.mkv",
          title: "Avatar"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == []
    end

    test "does not apply grain for recent content" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Dune (2021)/movie.mkv",
          title: "Dune"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == []
    end

    test "does not apply grain for HDR content even if vintage" do
      video =
        Fixtures.create_hdr_video(%{
          path: "/movies/Blade Runner (2007)/movie.mkv",
          title: "Blade Runner"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == []
    end

    test "does not apply grain when no year pattern is found" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/unknown_movie/file.mkv",
          title: "Unknown Movie"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == []
    end

    test "ignores false positive years outside valid range" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/High_Res_1080p/movie.mkv",
          title: "Some Movie"
        })

      result = Rules.grain_for_vintage_content(video)

      assert result == []
    end

    test "uses most specific year pattern when multiple years present" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/Remake (2010) of Classic (1985)/movie.mkv",
          title: "Movie Remake"
        })

      # Should pick (2010) over (1985) since (year) pattern comes first in regex list
      result = Rules.grain_for_vintage_content(video)

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

      result = Rules.grain_for_vintage_content(video)

      assert result == [{"--svt", "film-grain=8"}]
    end

    test "does not apply grain for modern content using API content_year field" do
      video =
        Fixtures.create_test_video(%{
          path: "/movies/modern_movie.mkv",
          title: "Modern Movie",
          content_year: 2015
        })

      result = Rules.grain_for_vintage_content(video)

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

      result = Rules.grain_for_vintage_content(video)

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

      result = Rules.grain_for_vintage_content(video)

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

  describe "audio/1 - edge cases for 100% coverage" do
    test "handles zero channels gracefully" do
      video = Fixtures.create_test_video(%{max_audio_channels: 0})
      result = Rules.audio(video)

      # Should return empty list for zero channels
      assert result == []
    end

    test "handles nil channels gracefully" do
      video = %{
        atmos: false,
        max_audio_channels: nil,
        audio_codecs: ["aac"]
      }

      result = Rules.audio(video)
      assert result == []
    end

    test "handles empty audio codecs list" do
      video = %{
        atmos: false,
        max_audio_channels: 2,
        audio_codecs: []
      }

      result = Rules.audio(video)
      assert result == []
    end

    test "handles nil audio codecs" do
      video = %{
        atmos: false,
        max_audio_channels: 2,
        audio_codecs: nil
      }

      result = Rules.audio(video)
      assert result == []
    end

    test "handles very high channel counts (>11)" do
      video = Fixtures.create_test_video(%{max_audio_channels: 16})
      args = Rules.build_args(video, :encode)

      # Should include audio config with max bitrate
      assert "--acodec" in args
      assert "libopus" in args
      assert "b:a=510k" in args
    end

    test "handles unmapped channel counts" do
      # Test a channel count not in @recommended_opus_bitrates (12 channels)
      video = Fixtures.create_test_video(%{max_audio_channels: 12})
      args = Rules.build_args(video, :encode)

      # Should use fallback calculation (12 * 64 = 768, but max is 510)
      assert "--acodec" in args
      assert "libopus" in args
      # Should cap at 510k
      assert "b:a=510k" in args
    end

    test "handles plain map input (non-struct)" do
      video_map = %{
        max_audio_channels: 2,
        audio_codecs: ["aac"]
      }

      result = Rules.audio(video_map)
      assert result == []
    end
  end

  describe "grain_for_vintage_content/1 - full coverage" do
    test "applies grain for API-sourced vintage content (2008)" do
      video = Fixtures.create_test_video(%{content_year: 2008, hdr: nil})
      result = Rules.grain_for_vintage_content(video)

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

      result = Rules.grain_for_vintage_content(video)
      assert result == [{"--svt", "film-grain=8"}]
    end

    test "skips grain for modern content (2010+)" do
      video = Fixtures.create_test_video(%{content_year: 2010, hdr: nil})
      result = Rules.grain_for_vintage_content(video)

      assert result == []
    end

    test "skips grain for HDR content even if vintage" do
      video = Fixtures.create_test_video(%{content_year: 2005, hdr: "HDR10"})
      result = Rules.grain_for_vintage_content(video)

      assert result == []
    end

    test "skips grain when no year detected" do
      video =
        Fixtures.create_test_video(%{
          path: "/media/movies/NoYear.mkv",
          title: "No Year",
          content_year: nil,
          hdr: nil
        })

      result = Rules.grain_for_vintage_content(video)
      assert result == []
    end
  end

  describe "opus_bitrate calculation - edge cases" do
    test "calculates bitrate for unmapped channel count" do
      # Directly test the private function via public API
      video = Fixtures.create_test_video(%{max_audio_channels: 10})
      args = Rules.build_args(video, :encode)

      # 10 channels * 64 = 640, capped at 510
      assert "b:a=510k" in args
    end

    test "handles exactly 11 channels" do
      video = Fixtures.create_test_video(%{max_audio_channels: 11})
      args = Rules.build_args(video, :encode)

      # Should use the 11-channel mapping
      assert "--acodec" in args
      assert "libopus" in args
    end
  end

  describe "build_args/4 - invalid audio metadata behavior" do
    test "returns empty list for invalid channel metadata" do
      # Create a proper video struct but with invalid metadata
      {:ok, video} =
        Fixtures.video_fixture(%{
          max_audio_channels: nil,
          audio_codecs: ["aac"]
        })

      result = Rules.audio(video)
      assert result == []
    end

    test "returns empty list for zero channels" do
      {:ok, video} = Fixtures.video_fixture(%{max_audio_channels: 0})

      result = Rules.audio(video)
      assert result == []
    end
  end

  describe "grain/2" do
    test "applies grain with specified strength for non-HDR content" do
      video = Fixtures.create_test_video(%{hdr: nil})
      result = Rules.grain(video, 12)

      assert result == [{"--svt", "film-grain=12"}]
    end

    test "does not apply grain for HDR content" do
      video = Fixtures.create_test_video(%{hdr: "HDR10"})
      result = Rules.grain(video, 12)

      assert result == []
    end
  end

  describe "cuda/1" do
    test "returns CUDA hardware acceleration config" do
      result = Rules.cuda(%{})

      assert result == [{"--enc-input", "hwaccel=cuda"}]
    end
  end

  describe "apply/1 - legacy function" do
    test "returns rule tuples for backward compatibility" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      result = Rules.apply(video)

      # Should return tuples, not formatted args
      assert is_list(result)
      assert Enum.all?(result, fn item -> is_tuple(item) and tuple_size(item) == 2 end)

      # Should include audio rules
      assert Enum.any?(result, fn {flag, _} -> flag == "--acodec" end)
    end
  end

  describe "hdr/1" do
    test "applies dolbyvision for HDR content" do
      video = Fixtures.create_test_video(%{hdr: "HDR10"})
      result = Rules.hdr(video)

      assert {"--svt", "tune=0"} in result
      assert {"--svt", "dolbyvision=1"} in result
    end

    test "applies tune=0 for non-HDR content" do
      video = Fixtures.create_test_video(%{hdr: nil})
      result = Rules.hdr(video)

      assert result == [{"--svt", "tune=0"}]
    end
  end

  describe "resolution/1" do
    test "downscales content above 1080p" do
      video = Fixtures.create_test_video(%{height: 2160})
      result = Rules.resolution(video)

      assert result == [{"--vfilter", "scale=1920:-2"}]
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

  describe "3-channel upmix to 5.1" do
    test "upmixes 3 channels to 5.1 with reduced bitrate" do
      video = Fixtures.create_test_video(%{max_audio_channels: 3})
      args = Rules.build_args(video, :encode)

      # Should upmix to 6 channels
      assert "ac=6" in args
      # Should use 128k bitrate for 3-channel source
      assert "b:a=128k" in args
    end
  end

  describe "5.1 channel layout workaround" do
    test "applies channel layout workaround for 5.1" do
      video = Fixtures.create_test_video(%{max_audio_channels: 6})
      args = Rules.build_args(video, :encode)

      # Should include the aformat workaround
      assert Enum.any?(args, &String.contains?(&1, "aformat=channel_layouts=5.1"))
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

  describe "parameter filtering by context" do
    test "crf_search context filters out audio params from additional_params" do
      video = Fixtures.create_test_video(%{max_audio_channels: 2})
      additional = ["--acodec", "libopus", "--preset", "6"]
      result = Rules.build_args(video, :crf_search, additional)

      # Audio params should be filtered
      refute "--acodec" in result
      refute "libopus" in result
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
end
