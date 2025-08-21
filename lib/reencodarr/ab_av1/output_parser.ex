defmodule Reencodarr.AbAv1.OutputParser do
  @moduledoc """
  Centralized parser for ab-av1 command output.

  This module handles all parsing of ab-av1 output in one place, converting raw string output
  to structured data immediately, avoiding repeated parsing throughout the application.
  """

  alias Reencodarr.Core.Parsers

  # Pattern definitions
  @patterns %{
    encoding_sample:
      ~r/encoding\ssample\s(?<sample_num>\d+)\/(?<total_samples>\d+)\scrf\s(?<crf>\d+(?:\.\d+)?)/,
    simple_vmaf:
      ~r/\[(?<timestamp>[^\]]+)\].*?crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/,
    sample_vmaf:
      ~r/sample\s(?<sample_num>\d+)\/(?<total_samples>\d+)\scrf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/,
    dash_vmaf: ~r/^-\scrf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/,
    eta_vmaf:
      ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\spredicted\svideo\sstream\ssize\s(?<size>\d+\.?\d*)\s(?<unit>\w+)\s\((?<percent>\d+)%\)\staking\s(?<time>\d+\.?\d*)\s(?<time_unit>\w+)/,
    vmaf_comparison: ~r/vmaf\s(?<file1>.+?)\svs\sreference\s(?<file2>.+)/,
    progress:
      ~r/\[(?<timestamp>[^\]]+)\].*?(?<progress>\d+(?:\.\d+)?)%,\s(?<fps>\d+(?:\.\d+)?)\sfps?,\seta\s(?<eta>\d+)\s(?<time_unit>second|minute|hour|day|week|month|year)s?/,
    success: ~r/(?:\[.*\]\s)?crf\s(?<crf>\d+(?:\.\d+)?)\ssuccessful/,
    warning: ~r/^Warning:\s(?<message>.*)/,
    encoding_start: ~r/\[.*\] encoding (?<filename>\d+\.mkv)/,
    encoding_progress:
      ~r/\[.*\]\s*(?<percent>\d+)%,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours|days|weeks|months|years)/,
    encoding_progress_alt:
      ~r/(?<percent>\d+)%,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours|days|weeks|months|years)/,
    file_size_progress: ~r/Encoded\s(?<size>[\d\.]+\s\w+)\s\((?<percent>\d+)%\)/,
    ffmpeg_error: ~r/Error: ffmpeg encode exit code (?<exit_code>\d+)/
  }
  @doc """
  Returns the centralized regex patterns for ab-av1 output parsing.

  This function provides access to the regex patterns for other modules
  that need to do pattern matching without duplicating the definitions.
  """
  @spec get_patterns() :: map()
  def get_patterns, do: @patterns

  @doc """
  Matches a line against a specific pattern and returns named captures.

  Returns nil if no match, or a map of captured values if matched.
  """
  @spec match_pattern(String.t(), atom()) :: map() | nil
  def match_pattern(line, pattern_key) do
    pattern = Map.get(@patterns, pattern_key)

    case Regex.named_captures(pattern, line) do
      nil -> nil
      captures -> captures
    end
  end

  @doc """
  Parses a single line of ab-av1 output and returns structured data.

  Returns `{:ok, parsed_data}` for recognized patterns, `:ignore` for irrelevant lines.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | :ignore
  def parse_line(line) do
    line = String.trim(line)

    # Try patterns in order of likelihood/importance
    pattern_attempts = [
      # CRF Search Progress Patterns
      {:encoding_sample, :encoding_sample},
      {:simple_vmaf, :vmaf_result},
      {:sample_vmaf, :sample_vmaf},
      {:dash_vmaf, :dash_vmaf},
      {:eta_vmaf, :eta_vmaf},
      {:vmaf_comparison, :vmaf_comparison},
      {:progress, :progress},
      {:success, :success},
      {:warning, :warning},
      # Encoding Progress Patterns
      {:encoding_start, :encoding_start},
      {:encoding_progress, :encoding_progress},
      # fallback for encoding progress
      {:encoding_progress_alt, :encoding_progress},
      {:file_size_progress, :file_size_progress},
      # Error Patterns
      {:ffmpeg_error, :ffmpeg_error}
    ]

    result =
      Enum.find_value(pattern_attempts, fn {pattern_key, type} ->
        field_mapping = field_mappings()[pattern_key]
        parse_pattern_with_mapping(line, pattern_key, type, field_mapping)
      end)

    result || :ignore
  end

  defp parse_pattern_with_mapping(_line, _pattern_key, _type, nil), do: nil

  defp parse_pattern_with_mapping(line, :encoding_start, type, _field_mapping) do
    case parse_encoding_start_pattern(line) do
      nil -> nil
      data -> {:ok, %{type: type, data: data}}
    end
  end

  defp parse_pattern_with_mapping(line, pattern_key, type, field_mapping) do
    case Parsers.parse_with_pattern(line, pattern_key, @patterns, field_mapping) do
      nil -> nil
      data -> {:ok, %{type: type, data: data}}
    end
  end

  # Special parser for encoding_start pattern with custom transformations
  defp parse_encoding_start_pattern(line) do
    pattern = @patterns[:encoding_start]

    case Regex.named_captures(pattern, line) do
      nil ->
        nil

      %{"filename" => filename} ->
        extname = Path.extname(filename)
        video_id = Parsers.parse_int(Path.basename(filename, extname))

        %{
          filename: filename,
          video_id: video_id
        }
    end
  end

  @doc """
  Parses multiple lines of ab-av1 output and returns structured results.

  Filters out ignored lines and returns only parsed data.
  """
  @spec parse_output(String.t() | [String.t()]) :: [map()]
  def parse_output(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> parse_output()
  end

  def parse_output(lines) when is_list(lines) do
    lines
    |> Enum.map(&parse_line/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, data} -> data end)
  end

  # Note: All individual parsing functions have been consolidated into ParseHelpers.
  # Pattern matching is now handled declaratively through @patterns and field_mappings().
  # This eliminates ~200 lines of repetitive regex parsing code.

  # Field mappings for different pattern types
  defp field_mappings do
    %{
      encoding_sample:
        Parsers.field_mapping([
          {:sample_num, :int},
          {:total_samples, :int},
          {:crf, :float}
        ]),
      simple_vmaf:
        Parsers.field_mapping([
          {:timestamp, :string},
          {:crf, :float},
          {:vmaf_score, :float, "score"},
          {:percent, :int}
        ]),
      sample_vmaf:
        Parsers.field_mapping([
          {:sample_num, :int},
          {:total_samples, :int},
          {:crf, :float},
          {:vmaf_score, :float, "score"},
          {:percent, :int}
        ]),
      dash_vmaf:
        Parsers.field_mapping([
          {:crf, :float},
          {:vmaf_score, :float, "score"},
          {:percent, :int}
        ]),
      eta_vmaf:
        Parsers.field_mapping([
          {:crf, :float},
          {:vmaf_score, :float, "score"},
          {:predicted_size, :float, "size"},
          {:size_unit, :string, "unit"},
          {:percent, :int},
          {:time_taken, :float, "time"},
          {:time_unit, :string}
        ]),
      vmaf_comparison:
        Parsers.field_mapping([
          {:file1, :string},
          {:file2, :string}
        ]),
      progress:
        Parsers.field_mapping([
          {:timestamp, :string},
          {:progress, :float},
          {:fps, :float},
          {:eta, :int},
          {:eta_unit, :string, "time_unit"}
        ]),
      success:
        Parsers.field_mapping([
          {:crf, :float}
        ]),
      warning:
        Parsers.field_mapping([
          {:message, :string}
        ]),
      encoding_start: %{
        filename: {"filename", &Function.identity/1},
        video_id:
          {"filename",
           fn filename ->
             extname = Path.extname(filename)
             Parsers.parse_int(Path.basename(filename, extname))
           end}
      },
      encoding_progress:
        Parsers.field_mapping([
          {:percent, :int},
          {:fps, :float},
          {:eta, :int},
          {:eta_unit, :string, "unit"}
        ]),
      encoding_progress_alt:
        Parsers.field_mapping([
          {:percent, :int},
          {:fps, :float},
          {:eta, :int},
          {:eta_unit, :string, "unit"}
        ]),
      file_size_progress:
        Parsers.field_mapping([
          {:encoded_size, :string, "size"},
          {:percent, :int}
        ]),
      ffmpeg_error:
        Parsers.field_mapping([
          {:exit_code, :int}
        ])
    }
  end
end
