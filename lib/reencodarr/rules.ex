defmodule Reencodarr.Rules do
  @moduledoc """
  Defines rules and recommendations for media encoding.

  Centralized argument building for ab-av1 commands with proper context handling.
  """

  require Logger
  alias Reencodarr.Media

  @opus_codec_tag "A_OPUS"

  @recommended_opus_bitrates %{
    # Mono - official recommendation
    1 => 48,
    # Stereo - official recommendation
    2 => 96,
    # 2.1 or 3.0 - (~53 kbps per channel)
    3 => 160,
    # 4.0 or 3.1 - (~48 kbps per channel)
    4 => 192,
    # 5.0 or 4.1 - (~45 kbps per channel)
    5 => 224,
    # 5.1 - official recommendation (~43 kbps per channel)
    6 => 256,
    # 6.1 - (~46 kbps per channel)
    7 => 320,
    # 7.1 - official recommendation (~56 kbps per channel)
    8 => 450,
    # 8.1 - (~56 kbps per channel)
    9 => 500,
    # 9.1 - Max supported bitrate
    10 => 510,
    # 9.2 - Max supported bitrate
    11 => 510
  }

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
  defp convert_params_to_tuples(params, context) do
    if params && is_list(params) do
      params
      |> params_list_to_tuples()
      |> filter_tuples_for_context(context)
    else
      []
    end
  end

  # Convert base arguments to tuples (no context filtering for base args)
  defp convert_base_args_to_tuples(base_args) do
    if base_args && is_list(base_args) do
      params_list_to_tuples(base_args)
    else
      []
    end
  end

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

            String.starts_with?(param, "--") or String.starts_with?(param, "-") ->
              # This is a flag (both long --flag and short -f forms), expect a value next
              {acc, param}

            # Filter out standalone file paths (they start with / and contain file extensions)
            String.starts_with?(param, "/") and String.contains?(param, ".") ->
              # Skip standalone file paths - they shouldn't be in params
              {acc, nil}

            true ->
              # Standalone value without a flag (like "crf-search", "encode"), treat as single arg
              {[{param, nil} | acc], nil}
          end
      end)

    Enum.reverse(result)
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
  def audio(
        %Media.Video{atmos: atmos, max_audio_channels: channels, audio_codecs: audio_codecs} =
          video
      ) do
    cond do
      atmos == true ->
        []

      is_nil(channels) or is_nil(audio_codecs) ->
        Logger.debug(
          "🔴 Invalid audio metadata for video #{video.id}: channels=#{inspect(channels)}, codecs=#{inspect(audio_codecs)}, path=#{video.path}"
        )

        []

      channels == 0 ->
        Logger.debug(
          "🔴 Zero audio channels for video #{video.id}: channels=#{channels}, codecs=#{inspect(audio_codecs)}, path=#{video.path}"
        )

        []

      @opus_codec_tag in audio_codecs ->
        []

      true ->
        build_opus_audio_config(channels)
    end
  end

  # Handle map inputs (for tests that don't use proper structs)
  def audio(%{} = _video_map), do: []

  defp build_opus_audio_config(channels) do
    # Log problematic inputs that would generate invalid audio arguments
    cond do
      is_nil(channels) ->
        Logger.warning("🔴 Invalid audio config: channels is nil - this should not happen")
        []

      channels == 0 ->
        Logger.warning("🔴 Invalid audio config: channels is 0 - indicates bad MediaInfo parsing")
        []

      channels < 0 ->
        Logger.warning(
          "🔴 Invalid audio config: channels is negative (#{channels}) - indicates corrupted data"
        )

        []

      channels == 3 ->
        [
          {"--acodec", "libopus"},
          {"--enc", "b:a=128k"},
          # Upmix to 5.1
          {"--enc", "ac=6"}
        ]

      true ->
        base_config = [
          {"--acodec", "libopus"},
          {"--enc", "b:a=#{opus_bitrate(channels)}k"},
          {"--enc", "ac=#{channels}"}
        ]

        # Add channel layout workaround for 5.1(side) -> 5.1 mapping
        # This handles the common FFmpeg error: "Invalid channel layout 5.1(side) for specified mapping family -1"
        if channels == 6 do
          base_config ++ [{"--enc", "af=aformat=channel_layouts=5.1"}]
        else
          base_config
        end
    end
  end

  defp opus_bitrate(channels) when channels > 11 do
    # For very high channel counts, use maximum supported bitrate
    510
  end

  defp opus_bitrate(channels) do
    # Use ~64 kbps per channel as fallback for unmapped channel counts
    calculated_bitrate = Map.get(@recommended_opus_bitrates, channels, min(510, channels * 64))

    # Log if we calculate a problematic bitrate
    if calculated_bitrate <= 0 do
      Logger.warning(
        "🔴 Invalid opus bitrate calculated: #{calculated_bitrate} for #{channels} channels"
      )
    end

    calculated_bitrate
  end

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

  Only applies to non-HDR content as HDR typically doesn't need grain synthesis.
  """
  @spec grain_for_vintage_content(Media.Video.t()) :: list()
  def grain_for_vintage_content(%Media.Video{hdr: nil, content_year: year} = video)
      when is_integer(year) and year < 2009 do
    strength = 8

    Logger.info(
      "Applying film grain (strength #{strength}) for vintage content from #{year} (API): #{Path.basename(video.path)}"
    )

    [{"--svt", "film-grain=#{strength}"}]
  end

  def grain_for_vintage_content(%Media.Video{hdr: nil, path: path, title: title}) do
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

  # Skip grain for HDR content or when no pattern detected
  def grain_for_vintage_content(_), do: []

  # Extract year from text using common patterns
  defp extract_year_from_text(text) do
    # Match patterns like (2008), [2008], .2008., 2008, etc.
    # Focus on years 1950-2030 to avoid false positives from other numbers
    patterns = [
      # (2008)
      ~r/\((\d{4})\)/,
      # [2008]
      ~r/\[(\d{4})\]/,
      # .2008.
      ~r/\.(\d{4})\./,
      # space-separated 2008
      ~r/\s(\d{4})\s/,
      # any 4-digit number (last resort)
      ~r/(\d{4})/
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, text) do
        [_, year_str] -> parse_valid_year(year_str)
        _ -> nil
      end
    end)
  end

  defp parse_valid_year(year_str) do
    case Integer.parse(year_str) do
      {year, ""} when year >= 1950 and year <= 2030 -> year
      _ -> nil
    end
  end

  @spec hdr(Media.Video.t()) :: list()
  def hdr(%Media.Video{hdr: hdr}) when not is_nil(hdr) do
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
end
