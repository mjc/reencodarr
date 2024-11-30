defmodule Reencodarr.AbAv1 do
  use GenServer
  alias Reencodarr.{Rules, Media}
  alias Reencodarr.AbAv1.Helper
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok),
    do:
      {:ok,
       %{args: [], last_vmaf: :none, mode: :none, port: :none, queue: :queue.new(), video: :none},
       {:continue, :resolve_ab_av1_path}}

  @impl true
  def handle_continue(:resolve_ab_av1_path, state) do
    ab_av1_path = System.find_executable("ab-av1") || :error
    {:noreply, Map.put(state, :ab_av1_path, ab_av1_path)}
  end

  @spec crf_search(Media.Video.t()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
  end

  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    GenServer.cast(__MODULE__, {:encode, vmaf})
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
  def handle_cast(_, %{ab_av1_path: :error} = state) do
    Logger.error("ab-av1 executable not found")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{ab_av1_path: path, port: :none} = state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "crf_search", video: video})
    args = ["crf-search"] ++ Helper.build_args(video.path, vmaf_percent, video)

    {:noreply,
     %{state | port: Helper.open_port(path, args), video: video, args: args, mode: :crf_search}}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: port} = state) when port != :none do
    Logger.info("Queueing crf search for video #{video.id}")
    new_queue = :queue.in({:crf_search, video, vmaf_percent}, state.queue)
    {:noreply, %{state | queue: new_queue}}
  end

  @impl true
  def handle_cast(
        {:encode, %Media.Vmaf{params: params} = vmaf},
        %{ab_av1_path: path, port: :none} = state
      ) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
      action: "encoding",
      video: vmaf.video
    })

    args =
      [
        "encode",
        "--crf",
        to_string(vmaf.crf),
        "-o",
        Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
        "-i"
      ] ++ params

    {:noreply,
     %{state | port: Helper.open_port(path, args), video: vmaf.video, args: args, mode: :encode}}
  end

  @impl true
  def handle_cast({:encode, vmaf}, %{port: port} = state) when port != :none do
    Logger.info("Queueing encode for video #{vmaf.video.id}")
    new_queue = :queue.in({:encode, vmaf}, state.queue)
    {:noreply, %{state | queue: new_queue}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port, mode: :crf_search} = state) do
    result =
      data
      |> String.split("\n", trim: true)
      |> Helper.parse_crf_search()
      |> Helper.attach_params(state.video, state.args)

    Logger.info("Parsed output: #{inspect(result)}")

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{
      action: "crf_search_result",
      result: {:ok, result}
    })

    {:noreply, %{state | last_vmaf: List.last(result)}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port, mode: :encode} = state) do
    Helper.update_encoding_progress(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, queue: queue, last_vmaf: last_vmaf, mode: :crf_search} = state
      ) do
    result =
      if exit_code in [0, 1] do
        {:ok, [Map.put(last_vmaf, "chosen", true)]}
      else
        {:error, "ab-av1 command failed with exit code #{exit_code}"}
      end

    Logger.info("Exit status: #{inspect(result)}")

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{
      action: "crf_search_result",
      result: result
    })

    case :queue.out(queue) do
      {{:value, {:crf_search, video, vmaf_percent}}, new_queue} ->
        GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
        {:noreply, %{state | port: :none, queue: new_queue, last_vmaf: :none, mode: :none}}

      {:empty, _} ->
        {:noreply, %{state | port: :none, last_vmaf: :none, mode: :none}}
    end
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, queue: queue, mode: :encode} = state
      ) do
    result =
      if exit_code == 0 do
        {:ok, "Encoding completed successfully"}
      else
        {:error, "ab-av1 command failed with exit code #{exit_code}"}
      end

    Logger.info("Exit status: #{inspect(result)}")

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{
      action: "encode_result",
      result: result
    })

    case :queue.out(queue) do
      {{:value, {:encode, vmaf}}, new_queue} ->
        GenServer.cast(__MODULE__, {:encode, vmaf})
        {:noreply, %{state | port: :none, queue: new_queue, mode: :none}}

      {:empty, _} ->
        {:noreply, %{state | port: :none, mode: :none}}
    end
  end
end

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

  def attach_params(vmafs, video, args) do
    filtered_args = remove_args(args, ["crf-search", "--min-vmaf", "--temp-dir"])
    Enum.map(vmafs, &(Map.put(&1, "video_id", video.id) |> Map.put("params", filtered_args)))
  end

  def remove_args(args, keys) do
    Enum.reduce(args, {[], false}, fn
      _arg, {acc, true} ->
        {acc, false}

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

  def build_rules(video) do
    Rules.apply(video)
    |> Enum.reject(fn {k, _v} -> k == :"--acodec" end)
    |> Enum.flat_map(fn {k, v} -> [to_string(k), to_string(v)] end)
  end

  def build_args(video_path, vmaf_percent, video) do
    rules = build_rules(video)

    base_args = [
      "-i",
      video_path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      temp_dir()
    ]

    Enum.concat(base_args, rules)
  end

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

  def convert_time_to_duration(%{"time" => time, "unit" => unit} = captures) do
    case Integer.parse(time) do
      {time_value, _} ->
        Map.put(captures, "time", convert_to_seconds(time_value, unit)) |> Map.delete("unit")

      :error ->
        captures
    end
  end

  def convert_time_to_duration(captures), do: captures

  def convert_to_seconds(time, "minutes"), do: time * 60
  def convert_to_seconds(time, "hours"), do: time * 3600
  def convert_to_seconds(time, _), do: time

  def temp_dir do
    cwd_temp_dir = Path.join([File.cwd!(), "tmp", "ab-av1"])

    if File.exists?(cwd_temp_dir) do
      cwd_temp_dir
    else
      Path.join(System.tmp_dir!(), "ab-av1")
    end
  end

  def update_encoding_progress(data, state) do
    case Regex.named_captures(
           ~r/\[.*\] encoding (?<filename>\d+\.mkv)|(?<percent>\d+)%\s*,\s*(?<fps>\d+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours)/,
           data
         ) do
      %{"filename" => filename} when not is_nil(filename) ->
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
          action: "encode:start",
          video: state.video,
          filename: filename
        })

      %{"percent" => percent, "fps" => fps, "eta" => eta, "unit" => unit}
      when not is_nil(percent) ->
        eta_seconds = convert_to_seconds(String.to_integer(eta), unit)

        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
          action: "encoding_progress",
          video: state.video,
          percent: String.to_integer(percent),
          fps: String.to_integer(fps),
          eta: eta_seconds
        })

      _ ->
        Logger.info("Encoding output: #{data}")
    end
  end

  def open_port(path, args) do
    Port.open({:spawn_executable, path}, [
      :binary,
      :exit_status,
      :line,
      :use_stdio,
      :stderr_to_stdout,
      {:args, args}
    ])
  end
end
