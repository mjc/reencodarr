defmodule Reencodarr.AbAv1 do
  @moduledoc """
  This module is the frontend for interacting with ab-av1.

  ab-av1 is an ffmpeg wrapper that simplifies the use of vmaf.
  """
  alias Reencodarr.Rules

  @crf_search_results ~r/
    crf \s (?<crf>\d+) \s
    VMAF \s (?<score>\d+\.\d+)
    (?: \s predicted \s video \s stream \s size \s (?<size>[\d\.]+ \s \w+))?
    \s \((?<percent>\d+)%\)
    (?: \s taking \s (?<time>\d+ \s (?:minutes|seconds|hours)))?
  /x

  @spec crf_search(Reencodarr.Media.Video.t()) :: list(map)
  def crf_search(video, vmaf_percent \\ 95) do
    rules =
      generate_rules(video)
      |> Enum.filter(fn
        {"--acodec", _} -> false
        _ -> true
      end)

    args = ["crf-search"] ++ build_args(video.path, vmaf_percent, rules)

    run_ab_av1(args)
    |> parse_crf_search()
    |> attach_params(video, args)
  end

  defp attach_params(vmafs, video, args) do
    Enum.map(vmafs, fn vmaf ->
      Map.merge(vmaf, %{
        "video_id" => video.id,
        "params" => Enum.filter(args, fn
          "crf-search" -> false
          _ -> true
        end)})
    end)
  end

  @spec auto_encode(Reencodarr.Media.Video.t()) :: list(String.t())
  def auto_encode(video, vmaf_percent \\ 95) do
    rules = generate_rules(video)
    args = ["auto-encode"] ++ build_args(video.path, vmaf_percent, rules)
    run_ab_av1(args)
  end

  defp generate_rules(video) do
    Rules.apply(video)
    |> Enum.flat_map(fn {k, v} -> [to_string(k), to_string(v)] end)
  end

  defp build_args(video_path, vmaf_percent, rules) do
    input_arg = ["-i", video_path]
    vmaf_arg = ["--min-vmaf", Integer.to_string(vmaf_percent)]
    temp_dir_arg = ["--temp-dir", temp_dir()]

    input_arg ++ vmaf_arg ++ temp_dir_arg ++ rules
  end

  @spec run_ab_av1([binary()]) :: list()
  def run_ab_av1(args) do
    case System.cmd(ab_av1_path(), args, into: [], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> Enum.flat_map(&String.split(&1, "\n"))
        |> Enum.filter(&(&1 |> String.trim() |> String.length() > 0))

      {output, exit_code} ->
        raise "ab-av1 command failed with exit code #{exit_code}: #{output}"
    end
  end

  defp parse_crf_search(output) do
    output
    |> Enum.flat_map(&parse_crf_search_line/1)
    |> mark_last_as_chosen()
  end

  defp mark_last_as_chosen(vmafs) do
    case Enum.split(vmafs, -1) do
      {init, [last]} -> init ++ [Map.put(last, "chosen", true)]
      _ -> vmafs
    end
  end

  defp parse_crf_search_line(line) do
    case Regex.named_captures(@crf_search_results, line) do
      nil ->
        []

      captures ->
        [
          captures
          |> Enum.filter(fn {_, v} -> v not in [nil, ""] end)
          |> Enum.into(%{})
        ]
    end
  end

  defp ab_av1_path do
    System.find_executable("ab-av1") || raise "ab-av1 not found"
  end

  defp temp_dir do
    Path.join(System.tmp_dir!(), "ab-av1")
  end
end
