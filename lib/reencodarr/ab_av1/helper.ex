defmodule Reencodarr.AbAv1.Helper do
  alias Reencodarr.Rules
  require Logger

  @crf_search_results ~r/
    crf \s (?<crf>\d+) \s
    VMAF \s (?<score>\d+\.\d+)
    (?: \s predicted \s video \s stream \s size \s (?<size>[\d\.]+ \s \w+))?
    \s \((?<percent>\d+)%\)
    (?: \s taking \s (?<time>\d+ \s (?<unit>minutes|seconds|hours)))?
    (?: \s predicted)?
  /x

  @spec attach_params(list(map()), Media.Video.t()) :: list(map())
  def attach_params(vmafs, video) do
    Enum.map(vmafs, &Map.put(&1, "video_id", video.id))
  end

  @spec remove_args(list(String.t()), list(String.t())) :: list(String.t())
  def remove_args(args, keys) do
    Enum.reduce(args, {[], false}, fn
      _arg, {acc, true} -> {acc, false}
      arg, {acc, false} -> if Enum.member?(keys, arg), do: {acc, true}, else: {[arg | acc], false}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec build_rules(Media.Video.t()) :: list(String.t())
  def build_rules(video) do
    Rules.apply(video)
    |> Enum.reject(fn {k, _v} -> k == "--acodec" end)
    |> Enum.flat_map(fn {k, v} -> [to_string(k), to_string(v)] end)
  end

  @spec build_args(String.t(), integer(), Media.Video.t()) :: list(String.t())
  def build_args(video_path, vmaf_percent, video) do
    base_args = [
      "-i",
      video_path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      temp_dir()
    ]

    Enum.concat(base_args, build_rules(video))
  end

  @spec parse_crf_search(list(String.t())) :: list(map())
  def parse_crf_search(output) do
    for line <- output,
        captures = Regex.named_captures(@crf_search_results, line),
        captures != nil do
      captures
      |> convert_time_to_duration()
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> Enum.into(%{})
    end
  end

  @spec convert_time_to_duration(map()) :: map()
  def convert_time_to_duration(%{"time" => time, "unit" => unit} = captures) do
    case Integer.parse(time) do
      {time_value, _} ->
        Map.put(captures, "time", convert_to_seconds(time_value, unit)) |> Map.delete("unit")

      :error ->
        captures
    end
  end

  def convert_time_to_duration(captures), do: captures

  @spec convert_to_seconds(integer(), String.t()) :: integer()
  def convert_to_seconds(time, "minutes"), do: time * 60
  def convert_to_seconds(time, "hours"), do: time * 3600
  def convert_to_seconds(time, _), do: time

  @spec temp_dir() :: String.t()
  def temp_dir do
    cwd_temp_dir = Path.join([File.cwd!(), "tmp", "ab-av1"])
    File.mkdir_p(cwd_temp_dir)
    if File.exists?(cwd_temp_dir), do: cwd_temp_dir, else: Path.join(System.tmp_dir!(), "ab-av1")
    "/home/mjc/.ab-av1"
  end

  @spec update_encoding_progress(String.t(), map()) :: :ok
  def update_encoding_progress(data, _state) do
    case Regex.named_captures(
           ~r/\[.*\] encoding (?<filename>\d+\.mkv)|(?<percent>\d+)%\s*,\s*(?<fps>\d+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours)/,
           data
         ) do
      %{"percent" => percent, "fps" => fps, "eta" => eta, "unit" => unit} when eta != "" ->
        eta_seconds = convert_to_seconds(String.to_integer(eta), unit)
        human_readable_eta = "#{eta} #{unit}"

        Logger.info("Encoding progress: #{percent}%, #{fps} fps, ETA: #{human_readable_eta}")
      _ ->
        Logger.info("Encoding should start for #{data}")
    end
  end

  @spec open_port([binary()]) :: port() | :error
  def open_port(args) do
    case System.find_executable("ab-av1") do
      nil ->
        Logger.error("ab-av1 executable not found")
        :error

      path ->
        Port.open({:spawn_executable, path}, [
          :binary,
          :exit_status,
          :line,
          :use_stdio,
          :stderr_to_stdout,
          args: args
        ])
    end
  end

  @spec dequeue(:queue.queue(), atom()) :: :queue.queue() | :empty
  def dequeue(queue, module) do
    case :queue.out(queue) do
      {{:value, {action, video, vmaf_percent}}, new_queue} ->
        GenServer.cast(module, {action, video, vmaf_percent})
        new_queue

      {:empty, _} ->
        :empty
    end
  end
end
