defmodule Reencodarr.AbAv1.OutputParser do
  @moduledoc """
  Simple parser for ab-av1 command output using regex patterns.

  Converts raw ab-av1 output lines to structured data types.
  """

  # Simple pattern map for all ab-av1 output types
  # Order matters - more specific patterns first
  @patterns [
    {:encoding_sample, ~r/encoding\ssample\s(\d+)\/(\d+)\scrf\s(\d+(?:\.\d+)?)/},
    {:eta_vmaf,
     ~r/crf\s(\d+(?:\.\d+)?)\sVMAF\s(\d+\.\d+)\spredicted\svideo\sstream\ssize\s(\d+\.?\d*)\s(\w+)\s\((\d+)%\)\staking\s(\d+\.?\d*)\s(\w+)/},
    {:sample_vmaf, ~r/sample\s(\d+)\/(\d+)\scrf\s(\d+(?:\.\d+)?)\sVMAF\s(\d+\.\d+)\s\((\d+)%\)/},
    {:dash_vmaf, ~r/^-\scrf\s(\d+(?:\.\d+)?)\sVMAF\s(\d+\.\d+)\s\((\d+)%\)/},
    {:vmaf_result, ~r/crf\s(\d+(?:\.\d+)?)\sVMAF\s(\d+\.\d+)\s\((\d+)%\)/},
    {:file_progress, ~r/Encoded\s(\d+\.?\d*)\s(\w+)\s\((\d+)%\)/},
    {:progress,
     ~r/(\d+(?:\.\d+)?)%,\s(\d+(?:\.\d+)?)\sfps?,\seta\s(\d+)\s(second|minute|hour|day|week|month|year)s?/},
    {:encoding_start, ~r/encoding\s(.+\.mkv)/},
    {:ffmpeg_error, ~r/Error:\sffmpeg\sencode\sexit\scode\s(\d+)/},
    {:success, ~r/crf\s(\d+(?:\.\d+)?)\ssuccessful/},
    {:warning, ~r/^Warning:\s(.*)$/},
    {:vmaf_comparison, ~r/vmaf\s(.+?)\svs\sreference\s(.+)/}
  ]

  @doc """
  Parse a single line of ab-av1 output.

  Returns `{:ok, %{type: atom, data: map}}` for recognized patterns,
  or `:ignore` for unrecognized lines.
  """
  def parse_line(line) do
    case find_match(line, @patterns) do
      {type, captures} -> {:ok, %{type: type, data: build_data(type, captures)}}
      nil -> :ignore
    end
  end

  @doc """
  Parse multiple lines of ab-av1 output.

  Returns a list of parsed results, filtering out ignored lines.
  """
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

  @doc """
  Test a specific pattern against a line. Used by tests.

  Returns named captures map or nil if no match.
  """
  def match_pattern(line, pattern_type) do
    case List.keyfind(@patterns, pattern_type, 0) do
      {^pattern_type, pattern} ->
        case Regex.run(pattern, line) do
          nil ->
            nil

          [_ | captures] ->
            # Convert numbered captures to named map based on pattern type
            convert_captures_to_named(pattern_type, captures)
        end

      nil ->
        nil
    end
  end

  # Convert numbered captures to named map for tests
  defp convert_captures_to_named(:sample_vmaf, [sample_num, total_samples, crf, score, percent]) do
    %{
      "sample_num" => sample_num,
      "total_samples" => total_samples,
      "crf" => crf,
      "score" => score,
      "percent" => percent
    }
  end

  defp convert_captures_to_named(:success, [crf]) do
    %{"crf" => crf}
  end

  defp convert_captures_to_named(_pattern_type, _captures), do: nil

  # Find the first matching pattern
  defp find_match(line, [{type, pattern} | rest]) do
    case Regex.run(pattern, line) do
      nil -> find_match(line, rest)
      [_ | captures] -> {type, captures}
    end
  end

  defp find_match(_line, []), do: nil

  # Build structured data from captures based on type
  defp build_data(:encoding_sample, [sample_num, total_samples, crf]) do
    %{
      sample_num: String.to_integer(sample_num),
      total_samples: String.to_integer(total_samples),
      crf: parse_number(crf)
    }
  end

  defp build_data(:vmaf_result, [crf, score, percent]) do
    %{crf: parse_number(crf), score: parse_number(score), percent: String.to_integer(percent)}
  end

  defp build_data(:sample_vmaf, [sample_num, total_samples, crf, score, percent]) do
    %{
      sample_num: String.to_integer(sample_num),
      total_samples: String.to_integer(total_samples),
      crf: parse_number(crf),
      score: parse_number(score),
      percent: String.to_integer(percent)
    }
  end

  defp build_data(:dash_vmaf, [crf, score, percent]) do
    %{crf: parse_number(crf), score: parse_number(score), percent: String.to_integer(percent)}
  end

  defp build_data(:eta_vmaf, [crf, score, size, unit, percent, time, time_unit]) do
    %{
      crf: parse_number(crf),
      score: parse_number(score),
      size: parse_number(size),
      unit: unit,
      percent: String.to_integer(percent),
      time: parse_number(time),
      time_unit: time_unit
    }
  end

  defp build_data(:progress, [progress, fps, eta, time_unit]) do
    %{
      progress: parse_number(progress),
      fps: parse_number(fps),
      eta: String.to_integer(eta),
      # "minutes" → "minute"
      eta_unit: String.replace_suffix(time_unit, "s", "")
    }
  end

  defp build_data(:file_progress, [size, unit, percent]) do
    %{
      size: parse_number(size),
      unit: unit,
      progress: String.to_integer(percent)
    }
  end

  defp build_data(:encoding_start, [filename]) do
    # Extract video ID from filename like "123.mkv"
    video_id =
      case Regex.run(~r/(\d+)\.mkv/, filename) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end

    %{filename: filename, video_id: video_id}
  end

  defp build_data(:ffmpeg_error, [exit_code]) do
    %{exit_code: String.to_integer(exit_code)}
  end

  defp build_data(:success, [crf]) do
    %{crf: parse_number(crf)}
  end

  defp build_data(:warning, [message]) do
    %{message: message}
  end

  defp build_data(:vmaf_comparison, [file1, file2]) do
    %{file1: file1, file2: file2}
  end

  # Parse number as float if it contains decimal, otherwise integer
  defp parse_number(str) do
    if String.contains?(str, ".") do
      String.to_float(str)
    else
      String.to_integer(str)
    end
  end
end
