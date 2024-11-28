defmodule Reencodarr.AbAv1 do
  @moduledoc """
    This module is the frontend for interacting with ab-av1.

    ab-av1 is an ffmpeg wrapper that simplifies the use of vmaf.
  """

  alias Reencodarr.Rules
  alias Reencodarr.Media.Video

  @spec crf_search(Video.t(), integer) :: {any(), non_neg_integer()}
  @spec crf_search(Reencodarr.Media.Video.t()) :: {any(), non_neg_integer()}
  def crf_search(video, vmaf_percent \\ 95) do
    rules = Rules.apply(video) |> Enum.map(fn {k, v} -> [to_string(k), to_string(v)] end) |> List.flatten()
    args = [
      "crf-search",
      "-i", video.path,
      "--min-vmaf", to_string(vmaf_percent),
      "--temp-dir", temp_dir(),
      ] ++ rules
    run_ab_av1(args)
  end

  @spec run_ab_av1([binary()]) :: {String.t(), non_neg_integer()}
  def run_ab_av1(args) do
    System.cmd(ab_av1_path(), args, use_stdio: true, stderr_to_stdout: true)
  end

  defp ab_av1_path do
    System.find_executable("ab-av1") || raise "ab-av1 not found"
  end

  defp temp_dir() do
    System.tmp_dir!() |> Path.join("ab-av1")
  end
end
