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
    (?: \s predicted)?
  /x

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{args: [], port: :none, video: :none, queue: :queue.new(), last_vmaf: nil}, {:continue, :resolve_ab_av1_path}}

  @impl true
  def handle_continue(:resolve_ab_av1_path, state) do
    ab_av1_path = System.find_executable("ab-av1") || :error
    {:noreply, Map.put(state, :ab_av1_path, ab_av1_path)}
  end

  @spec crf_search(Media.Video.t(), integer) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
  end

  @spec queue_length() :: integer
  def queue_length do
    GenServer.call(__MODULE__, :queue_length)
  end

  @impl true
  def handle_call(:queue_length, _from, %{queue: queue} = state) do
    {:reply, :queue.len(queue), state}
  end

  @impl true
  def handle_cast({:crf_search, _video, _vmaf_percent}, %{ab_av1_path: :error} = state) do
    Logger.error("ab-av1 executable not found")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{ab_av1_path: path, port: :none, queue: queue} = state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "searching", video: video})
    args = ["crf-search"] ++ build_args(video.path, vmaf_percent, build_rules(video))

    port = Port.open({:spawn_executable, path}, [:binary, :exit_status, :line, :use_stdio, :stderr_to_stdout, args: args])
    {:noreply, %{state | port: port, video: video, args: args, queue: queue}}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: port, queue: queue} = state) when port != :none do
    Logger.info("Queueing crf search for video #{video.id}")
    new_queue = :queue.in({:crf_search, video, vmaf_percent}, queue)
    {:noreply, %{state | queue: new_queue}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port, last_vmaf: _last_vmaf} = state) do
    output =
      case data do
        binary when is_binary(binary) -> String.split(binary, "\n", trim: true)
        _ -> []
      end
    parsed_output = parse_crf_search(output)
    result = attach_params(parsed_output, state.video, state.args)
    if length(result) > 1, do: Logger.info("Parsed output: #{inspect(result)}")
    last_vmaf = List.last(result)
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "crf_search_result", result: {:ok, result}})
    {:noreply, %{state | last_vmaf: last_vmaf}}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_code}}, %{port: port, queue: queue, last_vmaf: last_vmaf} = state) do
    result =
      if exit_code in [0, 1],
        do: {:ok, [Map.put(last_vmaf, "chosen", true)]},
        else: {:error, "ab-av1 command failed with exit code #{exit_code}"}

    Logger.info("Exit status: #{inspect(result)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "crf_search_result", result: result})

    case :queue.out(queue) do
      {{:value, {:crf_search, video, vmaf_percent}}, new_queue} ->
        GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
        {:noreply, %{state | port: :none, queue: new_queue, last_vmaf: nil}}
      {:empty, _} ->
        {:noreply, %{state | port: :none, last_vmaf: nil}}
    end
  end

  defp attach_params(vmafs, video, args) do
    filtered_args = remove_args(args, ["crf-search", "--min-vmaf", "--temp-dir"])
    Enum.map(vmafs, fn vmaf ->
      vmaf
      |> Map.put("video_id", video.id)
      |> Map.put("params", filtered_args)
    end)
  end

  defp remove_args(args, keys) do
    Enum.reduce(args, {[], false}, fn
      "crf-search", {acc, _} -> {acc, false}
      _arg, {acc, true} -> {acc, false}
      arg, {acc, false} ->
        if Enum.member?(keys, arg) do
          {acc, true}
        else
          {[arg | acc], false}
        end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp build_rules(video) do
    Rules.apply(video)
    |> Enum.reject(fn {k, _v} -> k == :"--acodec" end)
    |> Enum.flat_map(fn {k, v} -> [to_string(k), to_string(v)] end)
  end

  defp build_args(video_path, vmaf_percent, rules) do
    ["-i", video_path, "--min-vmaf", Integer.to_string(vmaf_percent), "--temp-dir", temp_dir()] ++
      rules
  end

  defp parse_crf_search(output) do
    for line <- output, captures = Regex.named_captures(@crf_search_results, line), captures != nil do
      captures
      |> convert_time_to_duration()
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> Enum.into(%{})
    end
  end

  defp convert_time_to_duration(%{"time" => time, "unit" => unit} = captures) do
    case Integer.parse(time) do
      {time_value, _} ->
        duration = convert_to_seconds(time_value, unit)
        captures |> Map.put("time", duration) |> Map.delete("unit")
      :error ->
        captures
    end
  end

  defp convert_time_to_duration(captures), do: captures

  defp convert_to_seconds(time, "minutes"), do: time * 60
  defp convert_to_seconds(time, "hours"), do: time * 3600
  defp convert_to_seconds(time, _), do: time

  defp temp_dir do
    if function_exported?(Mix, :env, 0) and Mix.env() == :dev do
      Path.join([File.cwd!(), "tmp", "ab-av1"])
    else
      Path.join(System.tmp_dir!(), "ab-av1")
    end
  end
end
