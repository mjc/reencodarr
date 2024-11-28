defmodule Reencodarr.AbAv1 do
  @moduledoc """
  This module is the frontend for interacting with ab-av1.

  ab-av1 is an ffmpeg wrapper that simplifies the use of vmaf.
  """

  alias Reencodarr.{Rules, Media.Video}

  @spec crf_search(Video.t(), integer) :: {any(), non_neg_integer()}
  def crf_search(video, vmaf_percent \\ 95) do
    rules = generate_rules(video) |> Enum.filter(fn {"--acodec", _} -> false; _ -> true end)
    args = ["crf-search"] ++ build_args(video.path, vmaf_percent, rules)
    run_ab_av1(args)
  end

  @spec auto_encode(Video.t(), integer) :: {binary(), non_neg_integer()}
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
      "-i", video_path,
      "--min-vmaf", Integer.to_string(vmaf_percent),
      "--temp-dir", temp_dir()
    ] ++ rules
  end

  @spec run_ab_av1([binary()]) :: {String.t(), non_neg_integer()}
  def run_ab_av1(args) do
    {output, exit_code} = System.cmd(ab_av1_path(), args, stderr_to_stdout: true)
    {output, exit_code}
  end

  defp ab_av1_path do
    System.find_executable("ab-av1") || raise "ab-av1 not found"
  end

  defp temp_dir do
    Path.join(System.tmp_dir!(), "ab-av1")
  end
end
