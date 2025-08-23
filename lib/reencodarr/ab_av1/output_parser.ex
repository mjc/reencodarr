defmodule Reencodarr.AbAv1.OutputParser do
  @moduledoc """
  Parser for ab-av1 command output using NimbleParsec.

  Converts raw ab-av1 output lines to structured data types.
  This implementation maintains compatibility with existing tests while providing
  better readability than regex patterns.
  """

  import NimbleParsec

  # Helper parsers for common patterns
  number =
    choice([
      ascii_string([?0..?9], min: 1)
      |> string(".")
      |> ascii_string([?0..?9], min: 1)
      |> reduce(:to_float),
      ascii_string([?0..?9], min: 1)
      |> reduce(:to_integer)
    ])

  # Helper functions for parsing
  defp to_float([int_part, ".", decimal_part]), do: String.to_float("#{int_part}.#{decimal_part}")
  defp to_integer([int_str]), do: String.to_integer(int_str)

  # Helper for optional timestamp prefix: "[2024-12-12T00:13:08Z INFO] "
  timestamp_prefix =
    optional(
      ignore(string("["))
      |> ignore(utf8_string([{:not, ?]}], min: 1))
      |> ignore(string("] "))
    )

  # Simple progress parser that handles optional timestamp prefix
  # Examples: "75%, 45.2 fps, eta 5 minutes" or "[timestamp] 75%, 45.2 fps, eta 5 minutes"
  progress =
    timestamp_prefix
    |> concat(number)
    |> ignore(string("%, "))
    |> concat(number)
    |> ignore(choice([string(" fps, eta "), string(" fps?, eta ")]))
    |> integer(min: 1)
    |> ignore(string(" "))
    |> choice([
      string("seconds") |> replace("second"),
      string("minutes") |> replace("minute"),
      string("hours") |> replace("hour"),
      string("days") |> replace("day"),
      string("weeks") |> replace("week"),
      string("months") |> replace("month"),
      string("years") |> replace("year"),
      string("second"),
      string("minute"),
      string("hour"),
      string("day"),
      string("week"),
      string("month"),
      string("year")
    ])
    |> reduce(:build_progress)

  # Simple file progress: "Encoded 2.5 GB (75%)"
  file_progress =
    timestamp_prefix
    |> ignore(string("Encoded "))
    |> concat(number)
    |> ignore(string(" "))
    |> choice([
      string("TB"),
      string("GB"),
      string("MB"),
      string("KB"),
      string("B"),
      string("GiB"),
      string("MiB")
    ])
    |> ignore(string(" ("))
    |> integer(min: 1)
    |> ignore(string("%)"))
    |> reduce(:build_file_progress)

  # Sample VMAF: "sample 1/5 crf 28 VMAF 91.33 (85%)"
  sample_vmaf =
    timestamp_prefix
    |> ignore(string("sample "))
    |> integer(min: 1)
    |> ignore(string("/"))
    |> integer(min: 1)
    |> ignore(string(" crf "))
    |> concat(number)
    |> ignore(string(" VMAF "))
    |> concat(number)
    |> ignore(string(" ("))
    |> integer(min: 1)
    |> ignore(string("%)"))
    |> optional(ignore(string(" (cache)")))
    |> reduce(:build_sample_vmaf)

  # VMAF result: "crf 28 VMAF 91.33 (85%)"
  vmaf_result =
    timestamp_prefix
    |> ignore(string("crf "))
    |> concat(number)
    |> ignore(string(" VMAF "))
    |> concat(number)
    |> ignore(string(" ("))
    |> integer(min: 1)
    |> ignore(string("%)"))
    |> optional(ignore(string(" (cache)")))
    |> reduce(:build_vmaf_result)

  # Dash VMAF: "- crf 28 VMAF 91.33 (85%)"
  dash_vmaf =
    timestamp_prefix
    |> ignore(string("- crf "))
    |> concat(number)
    |> ignore(string(" VMAF "))
    |> concat(number)
    |> ignore(string(" ("))
    |> integer(min: 1)
    |> ignore(string("%)"))
    |> optional(ignore(string(" (cache)")))
    |> reduce(:build_dash_vmaf)

  # ETA VMAF: "crf 28 VMAF 91.33 predicted video stream size 800.5 MB (85%) taking 120 seconds"
  eta_vmaf =
    timestamp_prefix
    |> ignore(string("crf "))
    |> concat(number)
    |> ignore(string(" VMAF "))
    |> concat(number)
    |> ignore(string(" predicted video stream size "))
    |> concat(number)
    |> ignore(string(" "))
    |> choice([
      string("GiB"),
      string("MiB"),
      string("KiB"),
      string("GB"),
      string("MB"),
      string("KB"),
      string("B")
    ])
    |> ignore(string(" ("))
    |> integer(min: 1)
    |> ignore(string("%) taking "))
    |> concat(number)
    |> ignore(string(" "))
    |> choice([string("seconds"), string("minutes"), string("hours")])
    |> optional(ignore(string(" (cache)")))
    |> reduce(:build_eta_vmaf)

  # Encoding sample: "encoding sample 1/5 crf 28"
  encoding_sample =
    timestamp_prefix
    |> ignore(string("encoding sample "))
    |> integer(min: 1)
    |> ignore(string("/"))
    |> integer(min: 1)
    |> ignore(string(" crf "))
    |> concat(number)
    |> reduce(:build_encoding_sample)

  # Success: "crf 24 successful"
  success =
    timestamp_prefix
    |> ignore(string("crf "))
    |> concat(number)
    |> ignore(string(" successful"))
    |> reduce(:build_success)

  # Warning: "Warning: message"
  warning =
    timestamp_prefix
    |> ignore(string("Warning: "))
    |> utf8_string([{:not, ?\n}], min: 1)
    |> reduce(:build_warning)

  # Encoding start: "encoding video.mkv" or "[timestamp] encoding 123.mkv"
  encoding_start =
    timestamp_prefix
    |> ignore(string("encoding "))
    |> utf8_string([{:not, ?\n}], min: 1)
    |> reduce(:build_encoding_start)

  # FFmpeg error: "Error: ffmpeg encode exit code 1"
  ffmpeg_error =
    timestamp_prefix
    |> ignore(string("Error: ffmpeg encode exit code "))
    |> integer(min: 1)
    |> reduce(:build_ffmpeg_error)

  # Main parser
  main_parser =
    choice([
      encoding_sample,
      eta_vmaf,
      sample_vmaf,
      dash_vmaf,
      vmaf_result,
      file_progress,
      progress,
      encoding_start,
      ffmpeg_error,
      success,
      warning
    ])

  defparsec(:parse_ab_av1_line, main_parser)

  # Build functions
  defp build_progress([percent, fps, eta, time_unit]) do
    %{
      type: :progress,
      data: %{
        progress: percent,
        fps: fps,
        eta: eta,
        eta_unit: time_unit
      }
    }
  end

  defp build_file_progress([size, unit, percent]) do
    %{
      type: :file_progress,
      data: %{
        size: size,
        unit: unit,
        progress: percent
      }
    }
  end

  defp build_sample_vmaf([sample_num, total_samples, crf, score, percent]) do
    %{
      type: :sample_vmaf,
      data: %{
        sample_num: sample_num,
        total_samples: total_samples,
        crf: crf,
        score: score,
        percent: percent
      }
    }
  end

  defp build_vmaf_result([crf, score, percent]) do
    %{
      type: :vmaf_result,
      data: %{
        crf: crf,
        score: score,
        percent: percent
      }
    }
  end

  defp build_dash_vmaf([crf, score, percent]) do
    %{
      type: :dash_vmaf,
      data: %{
        crf: crf,
        score: score,
        percent: percent
      }
    }
  end

  defp build_eta_vmaf([crf, score, size, unit, percent, time, time_unit]) do
    %{
      type: :eta_vmaf,
      data: %{
        crf: crf,
        score: score,
        size: size,
        unit: unit,
        percent: percent,
        time: time,
        time_unit: time_unit
      }
    }
  end

  defp build_encoding_sample([sample_num, total_samples, crf]) do
    %{
      type: :encoding_sample,
      data: %{
        sample_num: sample_num,
        total_samples: total_samples,
        crf: crf
      }
    }
  end

  defp build_success([crf]) do
    %{
      type: :success,
      data: %{crf: crf}
    }
  end

  defp build_warning([message]) do
    %{
      type: :warning,
      data: %{message: message}
    }
  end

  defp build_encoding_start([filename]) do
    video_id =
      case Regex.run(~r/(\d+)\.mkv/, filename) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end

    %{
      type: :encoding_start,
      data: %{filename: filename, video_id: video_id}
    }
  end

  defp build_ffmpeg_error([exit_code]) do
    %{
      type: :ffmpeg_error,
      data: %{exit_code: exit_code}
    }
  end

  @doc """
  Parse a single line of ab-av1 output.

  Returns `{:ok, %{type: atom, data: map}}` for recognized patterns,
  or `:ignore` for unrecognized lines.
  """
  def parse_line(line) do
    case parse_ab_av1_line(line) do
      {:ok, [result], "", %{}, {1, 0}, _column} ->
        {:ok, result}

      {:ok, [result], _rest, %{}, {1, 0}, _column} ->
        {:ok, result}

      {:error, _reason, _rest, _context, _line, _column} ->
        :ignore
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

  Returns string-keyed captures map (for compatibility with regex tests) or nil if no match.
  """
  def match_pattern(line, pattern_type) do
    case parse_line(line) do
      {:ok, %{type: ^pattern_type, data: data}} ->
        # Convert back to string-keyed map for test compatibility
        convert_to_string_captures(pattern_type, data)

      _ ->
        nil
    end
  end

  # Convert structured data back to string captures for test compatibility
  defp convert_to_string_captures(:sample_vmaf, data) do
    %{
      "sample_num" => Integer.to_string(data.sample_num),
      "total_samples" => Integer.to_string(data.total_samples),
      "crf" => number_to_string(data.crf),
      "score" => number_to_string(data.score),
      "percent" => Integer.to_string(data.percent)
    }
  end

  defp convert_to_string_captures(:vmaf_result, data) do
    %{
      "crf" => number_to_string(data.crf),
      "score" => number_to_string(data.score),
      "percent" => Integer.to_string(data.percent)
    }
  end

  defp convert_to_string_captures(:file_progress, data) do
    %{
      "size" => number_to_string(data.size),
      "unit" => data.unit,
      "percent" => Integer.to_string(data.progress)
    }
  end

  defp convert_to_string_captures(:progress, data) do
    %{
      "percent" => number_to_string(data.progress),
      "fps" => number_to_string(data.fps),
      "eta" => Integer.to_string(data.eta),
      "time_unit" =>
        if(String.ends_with?(data.eta_unit, "s"), do: data.eta_unit, else: data.eta_unit <> "s")
    }
  end

  defp convert_to_string_captures(_, data), do: data

  defp number_to_string(num) when is_float(num), do: Float.to_string(num)
  defp number_to_string(num) when is_integer(num), do: Integer.to_string(num)
end
