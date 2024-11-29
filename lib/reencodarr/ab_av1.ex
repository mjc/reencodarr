defmodule Reencodarr.AbAv1 do
  use GenServer
  alias Reencodarr.{Rules, Media}
  require Logger

  @crf_search_results ~r/
    crf \s (?<crf>\d+) \s
    VMAF \s (?<score>\d+\.\d+)
    (?: \s predicted \s video \s stream \s size \s (?<size>[\d\.]+ \s \w+))?
    \s \((?<percent>\d+)%\)
    (?: \s taking \s (?<time>\d+ \s (?<unit>minutes|seconds|hours)))?
  /x

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @spec crf_search(Media.Video.t(), integer) :: [any()]
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.call(__MODULE__, {:crf_search, video, vmaf_percent}, :infinity)
  end

  @spec encode(Reencodarr.Media.Vmaf.t()) :: {:ok, String.t()} | {:error, String.t()}
  def encode(vmaf) do
    GenServer.call(__MODULE__, {:encode, vmaf}, :infinity)
  end

  @impl true
  def handle_call({:crf_search, video, vmaf_percent}, _from, state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "searching", video: video})

    rules = build_rules(video)
    args = ["crf-search"] ++ build_args(video.path, vmaf_percent, rules)

    result =
      case run_ab_av1(args) do
        {:ok, output} ->
          output
          |> parse_crf_search()
          |> attach_params(video, args)
        {:error, reason} ->
          raise "CRF search failed: #{reason}"
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:encode, %Media.Vmaf{crf: crf, params: params, video: video}}, _from, state) do
    output_path = Path.join([temp_dir(), Path.basename(video.path)])
    args = ["encode", "--crf", to_string(crf), "-o", output_path] ++ params

    result =
      case run_ab_av1(args) do
        {:ok, _output} -> {:ok, output_path}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  defp attach_params(vmafs, video, args) do
    filtered_args = remove_args(args, ["crf-search", "--min-vmaf", "--temp-dir"])
    Enum.map(vmafs, &Map.put(&1, "video_id", video.id) |> Map.put("params", filtered_args))
  end

  defp remove_args(args, keys) do
    Enum.reduce(args, {[], false}, fn arg, {acc, skip} ->
      cond do
        skip -> {acc, false}
        Enum.member?(keys, arg) -> {acc, true}
        true -> {acc ++ [arg], false}
      end
    end)
    |> elem(0)
  end

  defp build_rules(video) do
    Rules.apply(video)
    |> Enum.reject(fn {k, _v} -> k == :"--acodec" end)
    |> Enum.flat_map(fn {k, v} -> [to_string(k), to_string(v)] end)
  end

  defp build_args(video_path, vmaf_percent, rules) do
    input_arg = ["-i", video_path]
    vmaf_arg = ["--min-vmaf", Integer.to_string(vmaf_percent)]
    temp_dir_arg = ["--temp-dir", temp_dir()]

    input_arg ++ vmaf_arg ++ temp_dir_arg ++ rules
  end

  @spec run_ab_av1([binary()]) :: {:ok, list()} | {:error, String.t()}
  defp run_ab_av1(args) do
    case ab_av1_path() do
      :error -> {:error, "ab-av1 executable not found"}
      path ->
        {output, exit_code} = System.cmd(path, args, into: [], stderr_to_stdout: true, lines: 1024)
        if exit_code in [0, 1], do: {:ok, output}, else: {:error, "ab-av1 command failed with exit code #{exit_code}: #{output}"}
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
        captures = convert_time_to_duration(captures)
        [
          captures
          |> Enum.filter(fn {_, v} -> v not in [nil, ""] end)
          |> Enum.into(%{})
        ]
    end
  end

  defp convert_time_to_duration(captures) do
    with time when not is_nil(time) and time != "" <- Map.get(captures, "time"),
         unit when not is_nil(unit) and unit != "" <- Map.get(captures, "unit"),
         {time_value, _} <- Integer.parse(time),
         duration <- convert_to_seconds(time_value, unit) do
      captures
      |> Map.put("time", duration)
      |> Map.delete("unit")
    else
      _ -> captures
    end
  end

  defp convert_to_seconds(time, "minutes"), do: time * 60
  defp convert_to_seconds(time, "hours"), do: time * 3600
  defp convert_to_seconds(time, _), do: time


  defp ab_av1_path do
    System.find_executable("ab-av1") || :error
  end

  defp temp_dir do
    if function_exported?(Mix, :env, 0) and Mix.env() == :dev do
      Path.join([File.cwd!(), "tmp", "ab-av1"])
    else
      Path.join(System.tmp_dir!(), "ab-av1")
    end
  end
end
