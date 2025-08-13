defmodule Reencodarr.AbAv1.OutputParser do
  @moduledoc """
  Centralized parser for ab-av1 command output.

  This module handles all parsing of ab-av1 output in one place, converting raw string output
  to structured data immediately, avoiding repeated parsing throughout the application.
  """

  alias Reencodarr.Core.Parsers

  @doc """
  Parses a single line of ab-av1 output and returns structured data.

  Returns `{:ok, parsed_data}` for recognized patterns, `:ignore` for irrelevant lines.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | :ignore
  def parse_line(line) do
    line = String.trim(line)

    cond do
      # CRF Search Progress Patterns
      data = parse_encoding_sample(line) -> {:ok, %{type: :encoding_sample, data: data}}
      data = parse_simple_vmaf(line) -> {:ok, %{type: :vmaf_result, data: data}}
      data = parse_sample_vmaf(line) -> {:ok, %{type: :sample_vmaf, data: data}}
      data = parse_dash_vmaf(line) -> {:ok, %{type: :dash_vmaf, data: data}}
      data = parse_eta_vmaf(line) -> {:ok, %{type: :eta_vmaf, data: data}}
      data = parse_vmaf_comparison(line) -> {:ok, %{type: :vmaf_comparison, data: data}}
      data = parse_progress(line) -> {:ok, %{type: :progress, data: data}}
      data = parse_success(line) -> {:ok, %{type: :success, data: data}}
      data = parse_warning(line) -> {:ok, %{type: :warning, data: data}}
      # Encoding Progress Patterns
      data = parse_encoding_start(line) -> {:ok, %{type: :encoding_start, data: data}}
      data = parse_encoding_progress(line) -> {:ok, %{type: :encoding_progress, data: data}}
      data = parse_file_size_progress(line) -> {:ok, %{type: :file_size_progress, data: data}}
      # Error Patterns
      data = parse_ffmpeg_error(line) -> {:ok, %{type: :ffmpeg_error, data: data}}
      true -> :ignore
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

  # === Private Parsing Functions ===

  # CRF Search patterns
  defp parse_encoding_sample(line) do
    regex =
      ~r/encoding\ssample\s(?<sample_num>\d+)\/(?<total_samples>\d+)\scrf\s(?<crf>\d+(?:\.\d+)?)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          sample_num: Parsers.parse_int(captures["sample_num"]),
          total_samples: Parsers.parse_int(captures["total_samples"]),
          crf: Parsers.parse_float(captures["crf"])
        }
    end
  end

  defp parse_simple_vmaf(line) do
    regex =
      ~r/\[(?<timestamp>[^\]]+)\].*?crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          timestamp: captures["timestamp"],
          crf: Parsers.parse_float(captures["crf"]),
          vmaf_score: Parsers.parse_float(captures["score"]),
          percent: Parsers.parse_int(captures["percent"])
        }
    end
  end

  defp parse_sample_vmaf(line) do
    regex =
      ~r/sample\s(?<sample_num>\d+)\/(?<total_samples>\d+)\scrf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          sample_num: Parsers.parse_int(captures["sample_num"]),
          total_samples: Parsers.parse_int(captures["total_samples"]),
          crf: Parsers.parse_float(captures["crf"]),
          vmaf_score: Parsers.parse_float(captures["score"]),
          percent: Parsers.parse_int(captures["percent"])
        }
    end
  end

  defp parse_dash_vmaf(line) do
    regex = ~r/^-\scrf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          crf: Parsers.parse_float(captures["crf"]),
          vmaf_score: Parsers.parse_float(captures["score"]),
          percent: Parsers.parse_int(captures["percent"])
        }
    end
  end

  defp parse_eta_vmaf(line) do
    regex =
      ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\spredicted\svideo\sstream\ssize\s(?<size>\d+\.?\d*)\s(?<unit>\w+)\s\((?<percent>\d+)%\)\staking\s(?<time>\d+\.?\d*)\s(?<time_unit>\w+)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          crf: Parsers.parse_float(captures["crf"]),
          vmaf_score: Parsers.parse_float(captures["score"]),
          predicted_size: Parsers.parse_float(captures["size"]),
          size_unit: captures["unit"],
          percent: Parsers.parse_int(captures["percent"]),
          time_taken: Parsers.parse_float(captures["time"]),
          time_unit: captures["time_unit"]
        }
    end
  end

  defp parse_vmaf_comparison(line) do
    regex = ~r/vmaf\s(?<file1>.+?)\svs\sreference\s(?<file2>.+)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          file1: String.trim(captures["file1"]),
          file2: String.trim(captures["file2"])
        }
    end
  end

  defp parse_progress(line) do
    regex =
      ~r/\[(?<timestamp>[^\]]+)\].*?(?<progress>\d+(?:\.\d+)?)%,\s(?<fps>\d+(?:\.\d+)?)\sfps?,\seta\s(?<eta>\d+)\s(?<time_unit>second|minute|hour|day|week|month|year)s?/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          timestamp: captures["timestamp"],
          progress: Parsers.parse_float(captures["progress"]),
          fps: Parsers.parse_float(captures["fps"]),
          eta: Parsers.parse_int(captures["eta"]),
          eta_unit: captures["time_unit"]
        }
    end
  end

  defp parse_success(line) do
    regex = ~r/(?:\[.*\]\s)?crf\s(?<crf>\d+(?:\.\d+)?)\ssuccessful/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          crf: Parsers.parse_float(captures["crf"])
        }
    end
  end

  defp parse_warning(line) do
    regex = ~r/^Warning:\s(?<message>.*)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          message: String.trim(captures["message"])
        }
    end
  end

  # Encoding patterns
  defp parse_encoding_start(line) do
    regex = ~r/\[.*\] encoding (?<filename>\d+\.mkv)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        filename = captures["filename"]
        extname = Path.extname(filename)
        video_id = Parsers.parse_int(Path.basename(filename, extname))

        %{
          filename: filename,
          video_id: video_id
        }
    end
  end

  defp parse_encoding_progress(line) do
    # Try main pattern first
    regex1 =
      ~r/\[.*\]\s*(?<percent>\d+)%,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours|days|weeks|months|years)/

    case Regex.named_captures(regex1, line) do
      nil ->
        # Try alternative pattern without timestamp
        regex2 =
          ~r/(?<percent>\d+)%,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours|days|weeks|months|years)/

        case Regex.named_captures(regex2, line) do
          nil -> nil
          captures -> build_encoding_progress(captures)
        end

      captures ->
        build_encoding_progress(captures)
    end
  end

  defp build_encoding_progress(captures) do
    %{
      percent: Parsers.parse_int(captures["percent"]),
      fps: Parsers.parse_float(captures["fps"]),
      eta: Parsers.parse_int(captures["eta"]),
      eta_unit: captures["unit"]
    }
  end

  defp parse_file_size_progress(line) do
    regex = ~r/Encoded\s(?<size>[\d\.]+\s\w+)\s\((?<percent>\d+)%\)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          encoded_size: String.trim(captures["size"]),
          percent: Parsers.parse_int(captures["percent"])
        }
    end
  end

  # Error patterns
  defp parse_ffmpeg_error(line) do
    regex = ~r/Error: ffmpeg encode exit code (?<exit_code>\d+)/

    case Regex.named_captures(regex, line) do
      nil ->
        nil

      captures ->
        %{
          exit_code: Parsers.parse_int(captures["exit_code"])
        }
    end
  end
end
