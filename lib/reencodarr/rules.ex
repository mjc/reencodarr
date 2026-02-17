defmodule Reencodarr.Rules do
  @moduledoc """
  Defines rules and recommendations for media encoding.

  Centralized argument building for ab-av1 commands with proper context handling.
  """

  require Logger
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Media

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
    rules_to_apply = [
      &hdr/1,
      &resolution/1,
      &video/1,
      &grain_for_vintage_content/1
    ]

    # Add audio rules only for encoding context
    rules_to_apply =
      if context == :encode do
        [(&audio/1) | rules_to_apply]
      else
        rules_to_apply
      end

    rule_tuples =
      video
      |> apply_rules(rules_to_apply)

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

    # Convert final tuples to arguments
    convert_to_args(all_tuples)
  end

  @doc """
  Legacy function for backward compatibility.
  Returns rule tuples instead of formatted arguments.
  """
  @spec apply(Media.Video.t()) :: [{String.t(), String.t()}]
  def apply(video) do
    rules_to_apply = [
      &audio/1,
      &hdr/1,
      &resolution/1,
      &video/1
    ]

    apply_rules(video, rules_to_apply)
  end

  # Apply a list of rule functions to a video
  defp apply_rules(video, rules_to_apply) do
    results =
      Enum.map(rules_to_apply, fn rule ->
        rule.(video)
      end)

    Enum.flat_map(results, & &1)
  end

  # Convert rule tuples to command line arguments
  defp convert_to_args(rule_tuples) do
    Enum.flat_map(rule_tuples, fn
      # Single args like "crf-search", "-i"
      {flag, nil} -> [to_string(flag)]
      # Flag-value pairs
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
              # This is a value for the previous flag
              {[{expecting_value, param} | acc], nil}

           is_flag?(param) ->
              # This is a flag (both long --flag and short -f forms), expect a value next
              {acc, param}

            is_file_path?(param) ->
              # Skip standalone file paths - they shouldn't be in params
              {acc, nil}

            is_standalone_value?(param) ->
              # Standalone value without a flag (like "crf-search", "encode"), treat as single arg
              {[{param, nil} | acc], nil}

            true ->
              # Unknown standalone value, skip it
              {acc, nil}
          end
      end)

    Enum.reverse(result)
  end

  # Public for testing
  @doc false
  def is_flag?(param) do
    String.starts_with?(param, "--") or String.starts_with?(param, "-")
  end

  @doc false
  def is_file_path?(param) do
    String.starts_with?(param, "/") and String.contains?(param, ".")
  end

  @doc false
  def is_standalone_value?(param) do
    # Only known subcommands are valid standalone values
    param in ["crf-search", "encode"]
  end

  # Separate subcommands (like "crf-search", "encode") from flags (like "--preset", "--input")
  # Filters out unknown standalone values
  defp separate_subcommands_and_flags(tuples) do
    known_subcommands = ["crf-search", "encode"]

    # Split into subcommands, valid flags, and unknown standalone values
    {subcommands, other_tuples} =
      Enum.split_with(tuples, fn {key, value} ->
        # Only allow known subcommands as standalone values
        is_nil(value) and key in known_subcommands
      end)

    # Filter out unknown standalone values from other_tuples
    valid_flags =
      Enum.filter(other_tuples, fn {key, value} ->
        # Keep flag-value pairs or known single flags like "-i"
        not is_nil(value) or String.starts_with?(key, "-")
      end)

    {subcommands, valid_flags}
  end

  # Filter tuples based on context (crf-search vs encode)
  defp filter_tuples_for_context(tuples, :crf_search) do
    # CRF search: exclude audio-related and file path params
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
    # Encode: exclude crf-search specific params and CRF range flags
    Enum.filter(tuples, fn {flag, _value} ->
      flag not in ["--temp-dir", "--min-vmaf", "--max-vmaf", "--min-crf", "--max-crf"]
    end)
  end

  # Remove duplicate tuples, keeping first occurrence
  # Special handling for --svt and --enc which can appear multiple times
  defp remove_duplicate_tuples(tuples) do
    # Map equivalent flags to canonical forms for deduplication
    flag_equivalents = %{
      "-i" => "--input",
      "-o" => "--output"
    }

    # First normalize all flags to canonical forms
    normalized_tuples =
      Enum.map(tuples, fn {flag, value} ->
        canonical_flag = Map.get(flag_equivalents, flag, flag)
        {canonical_flag, value}
      end)

    {result, _seen} =
      Enum.reduce(normalized_tuples, {[], MapSet.new()}, fn
        {flag, _value} = tuple, {acc, seen} ->
          # Allow multiple --svt and --enc flags since they can have different values
          if flag in ["--svt", "--enc"] or not MapSet.member?(seen, flag) do
            {[tuple | acc], MapSet.put(seen, flag)}
          else
            {acc, seen}
          end
      end)

    Enum.reverse(result)
  end

  @spec audio(Media.Video.t() | map()) :: list()
  def audio(%Media.Video{}), do: [{"--acodec", "copy"}]

  # Handle map inputs (for tests that don't use proper structs)
  def audio(%{} = _video_map), do: [{"--acodec", "copy"}]

  @spec cuda(any()) :: list()
  def cuda(_) do
    [{"--enc-input", "hwaccel=cuda"}]
  end

  @spec grain(Media.Video.t(), integer()) :: list()
  def grain(%Media.Video{hdr: nil}, strength) do
    [{"--svt", "film-grain=#{strength}"}]
  end

  def grain(_, _), do: []

  @doc """
  Applies film grain synthesis for vintage content (before 2009).

  Detects content from before 2009 using API-sourced year data when available,
  falling back to year patterns in path/title. Applies film grain with strength 8
  to preserve the authentic film aesthetic.

  For movies: uses release year
  For TV shows: uses series start year or episode air year

  Applies to both SDR and HDR content - vintage films that have been remastered
  to HDR still benefit from film grain synthesis to preserve the original look.
  """
  @spec grain_for_vintage_content(Media.Video.t()) :: list()
  def grain_for_vintage_content(%Media.Video{content_year: year} = video)
      when is_integer(year) and year < 2009 do
    strength = 8

    Logger.info(
      "Applying film grain (strength #{strength}) for vintage content from #{year} (API): #{Path.basename(video.path)}"
    )

    [{"--svt", "film-grain=#{strength}"}]
  end

  def grain_for_vintage_content(%Media.Video{path: path, title: title}) do
    strength = 8
    # Fallback to filename parsing for non-API sourced videos
    full_text = "#{path} #{title || ""}"

    case extract_year_from_text(full_text) do
      year when is_integer(year) and year < 2009 ->
        Logger.info(
          "Applying film grain (strength #{strength}) for vintage content from #{year} (parsed): #{Path.basename(path)}"
        )

        [{"--svt", "film-grain=#{strength}"}]

      _ ->
        []
    end
  end

  # Fallback when no year info available
  def grain_for_vintage_content(_), do: []

  @doc """
  Extract year from text using optimized parsing.

  Uses the high-performance Parsers.extract_year_from_text/1 function
  for maximum speed (20x faster than regex).

  ## Examples

      iex> Reencodarr.Rules.extract_year_from_text("The Movie (2008) HD")
      2008

      iex> Reencodarr.Rules.extract_year_from_text("Show.S01E01.2008.mkv")
      2008

      iex> Reencodarr.Rules.extract_year_from_text("No year here")
      nil

  """
  def extract_year_from_text(text) do
    Parsers.extract_year_from_text(text)
  end

  @spec hdr(Media.Video.t()) :: list()
  def hdr(%Media.Video{hdr: hdr}) when is_binary(hdr) do
    [
      {"--svt", "tune=0"},
      {"--svt", "dolbyvision=1"}
    ]
  end

  def hdr(_) do
    [{"--svt", "tune=0"}]
  end

  @spec resolution(Media.Video.t()) :: list()
  def resolution(%Media.Video{height: height}) when height > 1080 do
    [{"--vfilter", "scale=1920:-2"}]
  end

  def resolution(_) do
    []
  end

  @spec video(Media.Video.t()) :: list()
  def video(_) do
    [{"--pix-format", "yuv420p10le"}]
  end

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
  def vmaf_target(%{size: size}) when is_integer(size) and size > 60 * 1024 * 1024 * 1024, do: 91
  def vmaf_target(%{size: size}) when is_integer(size) and size > 40 * 1024 * 1024 * 1024, do: 92
  def vmaf_target(%{size: size}) when is_integer(size) and size > 25 * 1024 * 1024 * 1024, do: 94
  def vmaf_target(_video), do: 95
end
