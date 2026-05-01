defmodule Reencodarr.Rules do
  @moduledoc """
  Centralized argument building for ab-av1 commands.

  ## ab-av1 parameter routing

  - `{"--svt", "key=value"}` → `-svtav1-params key=value:...` (SVT-AV1 encoder params)
  - `{"--enc", "key=value"}` → `-key value` as ffmpeg output AVOption
  - `{"--encoder"|"--preset"|"--pix-format"|"--vfilter"|"--acodec", value}` → top-level ab-av1 flags

  SVT-AV1-HDR parameter reference: ~/projects/svt-av1-hdr/Docs/Parameters.md
  """

  require Logger
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Encoder.Capabilities
  alias Reencodarr.Media
  alias Reencodarr.Rules.Audio

  # Size thresholds for VMAF target selection (in bytes)
  @size_60_gib 60 * 1024 * 1024 * 1024
  @size_40_gib 40 * 1024 * 1024 * 1024
  @size_25_gib 25 * 1024 * 1024 * 1024

  # Film grain strength thresholds
  @grain_high_bitrate_threshold 20_000_000
  @grain_high_strength 20
  @grain_standard_strength 12
  @grain_stock_strength 8

  # HDR types that use the PQ transfer function (variance-boost-curve=3 applies)
  @pq_hdr ["HDR10", "HDR10+"]

  @doc """
  Build arguments for ab-av1 commands.

  ## Parameters
  - `video` - The video struct
  - `context` - `:crf_search` or `:encode` to determine which arguments to include
  - `additional_params` - Optional list of additional parameters (e.g., from VMAF retries)
  - `base_args` - Optional list of base arguments to include and deduplicate with

  ## Returns
  List of strings ready to be passed to ab-av1 command
  """
  @spec build_args(Media.Video.t(), :crf_search | :encode, list(), list()) :: [String.t()]
  def build_args(video, context, additional_params \\ [], base_args \\ []) do
    hdr_fork = Capabilities.svt_av1_hdr?()

    rules_to_apply = [
      &encoder/1,
      &preset/1,
      &hdr(&1, hdr_fork),
      &tune(&1, hdr_fork),
      &resolution/1,
      &video/1,
      &grain_for_vintage_content(&1, hdr_fork)
    ]

    # Add audio rules only for encoding context
    rules_to_apply =
      if context == :encode do
        [(&Audio.rules/1) | rules_to_apply]
      else
        rules_to_apply
      end

    rule_tuples = apply_rules(video, rules_to_apply)

    # Convert additional params from flat list to tuples, filtering based on context
    additional_tuples = convert_params_to_tuples(additional_params, context)

    # Convert base args to tuples
    base_tuples = convert_base_args_to_tuples(base_args)

    # Combine all tuples with proper ordering:
    # 1. Subcommands first (from base_args)
    # 2. Base flags next (should take precedence for deduplication)
    # 3. Additional params next
    # 4. Rule-based params last
    {subcommands, base_flags} = separate_subcommands_and_flags(base_tuples)

    combined_tuples = subcommands ++ base_flags ++ additional_tuples ++ rule_tuples

    all_tuples = remove_duplicate_tuples(combined_tuples)

    convert_to_args(all_tuples)
  end

  # Apply a list of rule functions to a video
  defp apply_rules(video, rules_to_apply) do
    Enum.flat_map(rules_to_apply, fn rule -> rule.(video) end)
  end

  # Convert rule tuples to command line arguments
  defp convert_to_args(rule_tuples) do
    Enum.flat_map(rule_tuples, fn
      {flag, nil} -> [to_string(flag)]
      {flag, value} -> [to_string(flag), to_string(value)]
    end)
  end

  # Convert parameter list from flat list to tuples, filtering based on context
  defp convert_params_to_tuples(params, context) when is_list(params) do
    params
    |> params_list_to_tuples()
    |> filter_tuples_for_context(context)
  end

  defp convert_params_to_tuples(_, _context), do: []

  # Convert base arguments to tuples (no context filtering for base args)
  defp convert_base_args_to_tuples(base_args) when is_list(base_args) do
    params_list_to_tuples(base_args)
  end

  defp convert_base_args_to_tuples(_), do: []

  # Convert flat parameter list (e.g., ["--preset", "6", "--cpu-used", "8"]) to tuples
  # Special handling for subcommands to ensure they come first
  defp params_list_to_tuples(params) do
    {result, _expecting_value} =
      Enum.reduce(params, {[], nil}, fn
        param, {acc, expecting_value} ->
          cond do
            expecting_value ->
              {[{expecting_value, param} | acc], nil}

            flag?(param) ->
              {acc, param}

            file_path?(param) ->
              {acc, nil}

            standalone_value?(param) ->
              {[{param, nil} | acc], nil}

            true ->
              {acc, nil}
          end
      end)

    Enum.reverse(result)
  end

  # Public for testing
  @doc false
  def flag?(param) do
    String.starts_with?(param, "--") or String.starts_with?(param, "-")
  end

  @doc false
  def file_path?(param) do
    String.starts_with?(param, "/") and String.contains?(param, ".")
  end

  @doc false
  def standalone_value?(param) do
    param in ["crf-search", "encode"]
  end

  defp separate_subcommands_and_flags(tuples) do
    known_subcommands = ["crf-search", "encode"]

    {subcommands, other_tuples} =
      Enum.split_with(tuples, fn {key, value} ->
        is_nil(value) and key in known_subcommands
      end)

    valid_flags =
      Enum.filter(other_tuples, fn {key, value} ->
        not is_nil(value) or String.starts_with?(key, "-")
      end)

    {subcommands, valid_flags}
  end

  defp filter_tuples_for_context(tuples, :crf_search) do
    Enum.filter(tuples, fn {flag, value} ->
      cond do
        flag in [
          "--temp-dir",
          "--min-vmaf",
          "--max-vmaf",
          "--acodec",
          "--downmix-to-stereo",
          "--video-only"
        ] ->
          false

        flag == "--enc" and (String.contains?(value, "b:a=") or String.contains?(value, "ac=")) ->
          false

        true ->
          true
      end
    end)
  end

  defp filter_tuples_for_context(tuples, :encode) do
    Enum.filter(tuples, fn {flag, _value} ->
      flag not in ["--temp-dir", "--min-vmaf", "--max-vmaf", "--min-crf", "--max-crf"]
    end)
  end

  # Remove duplicate tuples, keeping first occurrence.
  # --svt and --enc can appear multiple times with different values (e.g., multiple svt params),
  # so they deduplicate by exact {flag, value} pair rather than flag alone.
  defp remove_duplicate_tuples(tuples) do
    flag_equivalents = %{"-i" => "--input", "-o" => "--output"}

    normalized_tuples =
      Enum.map(tuples, fn {flag, value} ->
        {Map.get(flag_equivalents, flag, flag), value}
      end)

    {result, _seen} =
      Enum.reduce(normalized_tuples, {[], MapSet.new()}, fn
        {flag, _value} = tuple, {acc, seen} ->
          dedup_key = if flag in ["--svt", "--enc"], do: tuple, else: flag

          if MapSet.member?(seen, dedup_key) do
            {acc, seen}
          else
            {[tuple | acc], MapSet.put(seen, dedup_key)}
          end
      end)

    Enum.reverse(result)
  end

  # Thin delegator kept for callers that use the old name.
  @spec audio(Media.Video.t() | map()) :: list()
  def audio(video), do: Audio.rules(video)

  @spec cuda(any()) :: list()
  def cuda(_), do: [{"--enc-input", "hwaccel=cuda"}]

  @doc """
  Applies film grain synthesis for vintage content (before 2009).

  Detects content from before 2009 using API-sourced year data when available,
  falling back to year patterns in path/title.

  With the svt-av1-hdr fork:
  - Standard bitrate: film-grain=12 + film-grain-denoise=1 + adaptive-film-grain=1
  - High bitrate (≥20 Mbps): film-grain=20 + film-grain-denoise=1 + adaptive-film-grain=1

  Without the fork (stock SVT-AV1): film-grain=8 for all vintage content.
  """
  @spec grain_for_vintage_content(Media.Video.t(), boolean()) :: list()
  def grain_for_vintage_content(%Media.Video{content_year: year} = video, hdr_fork)
      when is_integer(year) and year < 2009 do
    grain_args(video, year, :api, hdr_fork)
  end

  def grain_for_vintage_content(%Media.Video{path: path, title: title} = video, hdr_fork) do
    case extract_year_from_text("#{path} #{title || ""}") do
      year when is_integer(year) and year < 2009 -> grain_args(video, year, :parsed, hdr_fork)
      _ -> []
    end
  end

  def grain_for_vintage_content(_, _), do: []

  defp grain_args(video, year, source, hdr_fork) do
    strength = grain_strength(video, hdr_fork)

    Logger.info(
      "Applying film grain (strength #{strength}) for vintage content from #{year} (#{source}): #{Path.basename(video.path)}"
    )

    base = [{"--svt", "film-grain=#{strength}"}]

    if hdr_fork do
      base ++ [{"--svt", "film-grain-denoise=1"}, {"--svt", "adaptive-film-grain=1"}]
    else
      base
    end
  end

  defp grain_strength(%Media.Video{bitrate: b}, hdr_fork)
       when is_integer(b) and b >= @grain_high_bitrate_threshold do
    if hdr_fork, do: @grain_high_strength, else: @grain_stock_strength
  end

  defp grain_strength(_, hdr_fork) do
    if hdr_fork, do: @grain_standard_strength, else: @grain_stock_strength
  end

  defp vintage_content?(%Media.Video{content_year: year}) when is_integer(year), do: year < 2009

  defp vintage_content?(%Media.Video{path: path, title: title}) do
    case extract_year_from_text("#{path} #{title || ""}") do
      year when is_integer(year) -> year < 2009
      _ -> false
    end
  end

  defp vintage_content?(_), do: false

  @doc """
  Extract year from text using optimized parsing.

  ## Examples

      iex> Reencodarr.Rules.extract_year_from_text("The Movie (2008) HD")
      2008

      iex> Reencodarr.Rules.extract_year_from_text("Show.S01E01.2008.mkv")
      2008

      iex> Reencodarr.Rules.extract_year_from_text("No year here")
      nil

  """
  def extract_year_from_text(text), do: Parsers.extract_year_from_text(text)

  @spec encoder(Media.Video.t()) :: list()
  def encoder(_), do: [{"--encoder", "svt-av1"}]

  @spec preset(Media.Video.t()) :: list()
  def preset(%Media.Video{height: height}) when is_integer(height) and height >= 1080,
    do: [{"--preset", "4"}]

  def preset(_), do: [{"--preset", "6"}]

  @doc """
  HDR-specific encoder flags.

  - DV: passes `-dolbyvision 1` to ffmpeg via `--enc` (ffmpeg libsvtav1 AVOption,
    not a svtav1-params key — must go through `--enc`, not `--svt`)
  - HDR10/HDR10+ with hdr fork: `variance-boost-curve=3` (PQ-optimised perceptual curve)
  - HLG and other HDR types: no curve override (default curve=0 is correct for non-PQ)
  - SDR or stock encoder: no HDR flags
  """
  @spec hdr(Media.Video.t(), boolean()) :: list()
  def hdr(%Media.Video{hdr: "DV"}, _hdr_fork), do: [{"--enc", "dolbyvision=1"}]

  def hdr(%Media.Video{hdr: hdr}, true) when hdr in @pq_hdr,
    do: [{"--svt", "variance-boost-curve=3"}]

  def hdr(_, _), do: []

  @doc """
  Tune mode selection.

  - Stock SVT-AV1: tune=0 (VQ — subjective quality, recommended for personal use)
  - svt-av1-hdr + vintage content: tune=5 (Film Grain mode)
  - svt-av1-hdr + modern content: tune=2 (SSIM)
  """
  @spec tune(Media.Video.t(), boolean()) :: list()
  def tune(video, hdr_fork) do
    cond do
      hdr_fork && vintage_content?(video) -> [{"--svt", "tune=5"}]
      hdr_fork -> [{"--svt", "tune=2"}]
      true -> [{"--svt", "tune=0"}]
    end
  end

  @spec resolution(Media.Video.t()) :: list()
  def resolution(%Media.Video{height: height}) when is_integer(height) and height >= 2160,
    do: [{"--vfilter", "scale=1920:-2"}]

  def resolution(_), do: []

  @spec video(Media.Video.t()) :: list()
  def video(_), do: [{"--pix-format", "yuv420p10le"}]

  @doc """
  Determines the target VMAF score based on file size.

  Larger files get lower VMAF targets to achieve better compression
  while maintaining acceptable quality:
  - >60 GiB: VMAF 91
  - >40 GiB: VMAF 92
  - >25 GiB: VMAF 94
  - Default: VMAF 95

  ## Examples

      iex> Reencodarr.Rules.vmaf_target(%{size: 100 * 1024 * 1024 * 1024})
      91

      iex> Reencodarr.Rules.vmaf_target(%{size: 50 * 1024 * 1024 * 1024})
      92

      iex> Reencodarr.Rules.vmaf_target(%{size: 10 * 1024 * 1024 * 1024})
      95
  """
  @spec vmaf_target(map()) :: integer()
  def vmaf_target(%{size: size}) when is_integer(size) and size > @size_60_gib, do: 91
  def vmaf_target(%{size: size}) when is_integer(size) and size > @size_40_gib, do: 92
  def vmaf_target(%{size: size}) when is_integer(size) and size > @size_25_gib, do: 94
  def vmaf_target(_video), do: 95

  @doc """
  The lowest VMAF target we'll accept after retry reduction.

  Up to 2 points below `vmaf_target/1` for the same video, with an
  absolute floor of 90. This gives CRF search room to recover when a
  source misses the initial target by a small amount.

  ## Examples

      iex> Reencodarr.Rules.min_vmaf_target(%{size: 100 * 1024 * 1024 * 1024})
      90

      iex> Reencodarr.Rules.min_vmaf_target(%{size: 10 * 1024 * 1024 * 1024})
      94
  """
  @spec min_vmaf_target(map()) :: integer()
  def min_vmaf_target(video), do: max(90, vmaf_target(video) - 2)
end
