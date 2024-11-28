defmodule Reencodarr.AbAv1 do
  @moduledoc """
  This module is the frontend for interacting with ab-av1.

  ab-av1 is an ffmpeg wrapper that simplifies the use of vmaf.
  """
  alias Reencodarr.Rules

  @crf_search_results ~r/crf (?<crf>\d+) VMAF (?<vmaf>\d+\.\d+)(?: predicted video stream size (?<size>[\d\.]+ \w+))? \((?<percent>\d+)%\)(?: taking (?<time>\d+) minutes)?/

  def crf_search(video, vmaf_percent \\ 95) do
    rules =
      generate_rules(video)
      |> Enum.filter(fn
        {"--acodec", _} -> false
        _ -> true
      end)

    args = ["crf-search"] ++ build_args(video.path, vmaf_percent, rules)
    {output, exit_code} = run_ab_av1(args)
    {parse_output(output), exit_code}
  end

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
    [
      "-i",
      video_path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      temp_dir()
    ] ++ rules
  end

  def run_ab_av1(args) do
    {output, exit_code} = System.cmd(ab_av1_path(), args, stderr_to_stdout: true)
    {output, exit_code}
  end

  defp parse_output(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    case Regex.named_captures(@crf_search_results, line) do
      %{"crf" => crf, "vmaf" => vmaf, "percent" => percent} = captures ->
        [
          %{
            crf: String.to_integer(crf),
            vmaf: String.to_float(vmaf),
            percent: String.to_integer(percent)
          }
          |> Map.merge(optional_fields(captures))
        ]

      _ ->
        []
    end
  end

  defp optional_fields(captures) do
    Enum.reduce(captures, %{}, fn
      {"size", size}, acc when size != nil and size != "" ->
        Map.put(acc, :size, size)

      {"time", time}, acc when time != nil and time != "" ->
        Map.put(acc, :time, String.to_integer(time))

      _, acc ->
        acc
    end)
  end

  defp ab_av1_path do
    System.find_executable("ab-av1") || raise "ab-av1 not found"
  end

  defp temp_dir do
    Path.join(System.tmp_dir!(), "ab-av1")
  end
end
