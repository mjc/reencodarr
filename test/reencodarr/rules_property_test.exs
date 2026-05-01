defmodule Reencodarr.RulesPropertyTest do
  @moduledoc """
  Property-based tests for the Rules module.

  These tests verify that rule functions behave correctly across
  a wide range of generated inputs, covering VMAF targeting and
  argument building for ab-av1 commands.
  """

  use Reencodarr.UnitCase, async: true
  use ExUnitProperties

  alias Reencodarr.Rules
  import StreamData

  @moduletag :property

  @valid_vmaf_targets [91, 92, 94, 95]
  @valid_min_vmaf_targets [90, 92, 93]

  # Generator for non-negative video sizes (0 to ~186 GiB)
  defp video_size_gen do
    integer(0..200_000_000_000)
  end

  defp video_map_gen do
    gen all(
          size <- video_size_gen(),
          width <- member_of([720, 1280, 1920, 3840]),
          hdr <- member_of([nil, "HDR10", "Dolby Vision"]),
          audio_codecs <- member_of([["aac"], ["opus"], ["ac3", "aac"]]),
          max_channels <- member_of([2, 6, 8]),
          atmos <- boolean()
        ) do
      %{
        size: size,
        width: width,
        height: div(width * 9, 16),
        hdr: hdr,
        audio_codecs: audio_codecs,
        video_codecs: ["hevc"],
        max_audio_channels: max_channels,
        atmos: atmos,
        series_name: nil
      }
    end
  end

  describe "vmaf_target/1 properties" do
    property "always returns a valid VMAF target" do
      check all(size <- video_size_gen()) do
        result = Rules.vmaf_target(%{size: size})
        assert result in @valid_vmaf_targets
      end
    end

    property "is monotonically non-increasing with file size" do
      check all(
              size_a <- video_size_gen(),
              size_b <- video_size_gen()
            ) do
        if size_a >= size_b do
          assert Rules.vmaf_target(%{size: size_a}) <= Rules.vmaf_target(%{size: size_b})
        end
      end
    end

    property "larger files get lower or equal VMAF targets" do
      check all(
              small <- integer(0..25_000_000_000),
              large <- integer(60_000_000_001..200_000_000_000)
            ) do
        assert Rules.vmaf_target(%{size: large}) <= Rules.vmaf_target(%{size: small})
      end
    end
  end

  describe "min_vmaf_target/1 properties" do
    property "is up to 2 below vmaf_target with floor of 90" do
      check all(size <- video_size_gen()) do
        video = %{size: size}
        assert Rules.min_vmaf_target(video) == max(90, Rules.vmaf_target(video) - 2)
      end
    end

    property "always returns a valid min VMAF target" do
      check all(size <- video_size_gen()) do
        result = Rules.min_vmaf_target(%{size: size})
        assert result in @valid_min_vmaf_targets
      end
    end
  end

  describe "build_args/4 properties" do
    property "returns a flat list of strings" do
      check all(
              video <- video_map_gen(),
              context <- member_of([:crf_search, :encode])
            ) do
        args = Rules.build_args(video, context)
        assert is_list(args)
        assert Enum.all?(args, &is_binary/1)
      end
    end

    property "no duplicate flags in output (excluding multi-value flags)" do
      check all(
              video <- video_map_gen(),
              context <- member_of([:crf_search, :encode])
            ) do
        args = Rules.build_args(video, context)

        # --svt and --enc are intentionally multi-value flags
        flags =
          args
          |> Enum.filter(&String.starts_with?(&1, "--"))
          |> Enum.reject(&(&1 in ["--svt", "--enc"]))

        assert flags == Enum.uniq(flags),
               "Duplicate flags found: #{inspect(flags -- Enum.uniq(flags))}"
      end
    end

    property "encode context includes audio codec, crf_search does not" do
      check all(video <- video_map_gen()) do
        encode_args = Rules.build_args(video, :encode)
        crf_args = Rules.build_args(video, :crf_search)

        assert "--acodec" in encode_args
        refute "--acodec" in crf_args
      end
    end

    property "always includes encoder selection" do
      check all(
              video <- video_map_gen(),
              context <- member_of([:crf_search, :encode])
            ) do
        args = Rules.build_args(video, context)
        assert "--encoder" in args
      end
    end
  end
end
