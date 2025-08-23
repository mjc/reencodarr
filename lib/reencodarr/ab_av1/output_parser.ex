defmodule Reencodarr.AbAv1.OutputParser do
  @moduledoc """
  Simple parser for ab-av1 command output using regex patterns.

  Converts raw ab-av1 output lines to structured data types.
  """

  # Simple pattern map for all ab-av1 output types
  # Order matters - more specific patterns first
  @patterns [
    {:encoding_sample,
     ~r/encoding\ssample\s(?<sample_num>\d+)\/(?<total_samples>\d+)\scrf\s(?<crf>\d+(?:\.\d+)?)/},
    {:eta_vmaf,
     ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\spredicted\svideo\sstream\ssize\s(?<size>\d+\.?\d*)\s(?<unit>\w+)\s\((?<percent>\d+)%\)\staking\s(?<time>\d+\.?\d*)\s(?<time_unit>\w+)/},
    {:sample_vmaf,
     ~r/sample\s(?<sample_num>\d+)\/(?<total_samples>\d+)\scrf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/},
    {:dash_vmaf,
     ~r/^-\scrf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/},
    {:vmaf_result,
     ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/},
    {:file_progress, ~r/Encoded\s(?<size>\d+\.?\d*)\s(?<unit>\w+)\s\((?<percent>\d+)%\)/},
    {:progress,
     ~r/(?<percent>\d+(?:\.\d+)?)%,\s(?<fps>\d+(?:\.\d+)?)\sfps?,\seta\s(?<eta>\d+)\s(?<time_unit>second|minute|hour|day|week|month|year)s?/},
    {:encoding_start, ~r/encoding\s(?<filename>.+\.mkv)/},
    {:ffmpeg_error, ~r/Error:\sffmpeg\sencode\sexit\scode\s(?<exit_code>\d+)/},
    {:success, ~r/crf\s(?<crf>\d+(?:\.\d+)?)\ssuccessful/},
    {:warning, ~r/^Warning:\s(?<message>.*)$/},
    {:vmaf_comparison, ~r/vmaf\s(?<file1>.+?)\svs\sreference\s(?<file2>.+)/}
  ]

  @doc """
  Parse a single line of ab-av1 output.

  Returns `{:ok, %{type: atom, data: map}}` for recognized patterns,
  or `:ignore` for unrecognized lines.
  """
  def parse_line(line) do
    case find_match(line) do
      {type, captures} -> {:ok, %{type: type, data: convert_captures(type, captures)}}
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
        Regex.named_captures(pattern, line)

      nil ->
        nil
    end
  end

  # Find the first matching pattern using named captures
  defp find_match(line) do
    Enum.find_value(@patterns, fn {type, pattern} ->
      case Regex.named_captures(pattern, line) do
        nil -> nil
        captures -> {type, captures}
      end
    end)
  end

  # Convert string-keyed captures to atom-keyed maps with appropriate types
  defp convert_captures(:encoding_sample, captures) do
    %{
      sample_num: String.to_integer(captures["sample_num"]),
      total_samples: String.to_integer(captures["total_samples"]),
      crf: parse_number(captures["crf"])
    }
  end

  defp convert_captures(:vmaf_result, captures) do
    %{
      crf: parse_number(captures["crf"]),
      score: parse_number(captures["score"]),
      percent: String.to_integer(captures["percent"])
    }
  end

  defp convert_captures(:sample_vmaf, captures) do
    %{
      sample_num: String.to_integer(captures["sample_num"]),
      total_samples: String.to_integer(captures["total_samples"]),
      crf: parse_number(captures["crf"]),
      score: parse_number(captures["score"]),
      percent: String.to_integer(captures["percent"])
    }
  end

  defp convert_captures(:dash_vmaf, captures) do
    %{
      crf: parse_number(captures["crf"]),
      score: parse_number(captures["score"]),
      percent: String.to_integer(captures["percent"])
    }
  end

  defp convert_captures(:eta_vmaf, captures) do
    %{
      crf: parse_number(captures["crf"]),
      score: parse_number(captures["score"]),
      size: parse_number(captures["size"]),
      unit: captures["unit"],
      percent: String.to_integer(captures["percent"]),
      time: parse_number(captures["time"]),
      time_unit: captures["time_unit"]
    }
  end

  defp convert_captures(:progress, captures) do
    %{
      progress: parse_number(captures["percent"]),
      fps: parse_number(captures["fps"]),
      eta: String.to_integer(captures["eta"]),
      # "minutes" → "minute"
      eta_unit: String.replace_suffix(captures["time_unit"], "s", "")
    }
  end

  defp convert_captures(:file_progress, captures) do
    %{
      size: parse_number(captures["size"]),
      unit: captures["unit"],
      progress: String.to_integer(captures["percent"])
    }
  end

  defp convert_captures(:encoding_start, captures) do
    filename = captures["filename"]
    # Extract video ID from filename like "123.mkv"
    video_id =
      case Regex.run(~r/(\d+)\.mkv/, filename) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end

    %{filename: filename, video_id: video_id}
  end

  defp convert_captures(:ffmpeg_error, captures) do
    %{exit_code: String.to_integer(captures["exit_code"])}
  end

  defp convert_captures(:success, captures) do
    %{crf: parse_number(captures["crf"])}
  end

  defp convert_captures(:warning, captures) do
    %{message: captures["message"]}
  end

  defp convert_captures(:vmaf_comparison, captures) do
    %{file1: captures["file1"], file2: captures["file2"]}
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
