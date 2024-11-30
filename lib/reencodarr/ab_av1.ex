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
       %{args: [], last_vmaf: :none, mode: :none, port: :none, queue: :queue.new(), video: :none, crf_searches: 0, encodes: 0},
       {:continue, :resolve_ab_av1_path}}

  @impl true
  def handle_continue(:resolve_ab_av1_path, state) do
    ab_av1_path = System.find_executable("ab-av1") || :error
    {:noreply, Map.put(state, :ab_av1_path, ab_av1_path)}
  end

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
  end

  @spec encode(Media.Vmaf.t(), atom()) :: :ok
  def encode(vmaf, position \\ :end) do
    GenServer.cast(__MODULE__, {:encode, vmaf, position})
  end

  @spec queue_length() :: %{crf_searches: integer(), encodes: integer()}
  def queue_length do
    GenServer.call(__MODULE__, :queue_length)
  end

  @impl true
  def handle_call(:queue_length, _from, %{crf_searches: crf_searches, encodes: encodes} = state) do
    {:reply, %{crf_searches: crf_searches, encodes: encodes}, state}
  end

  @impl true
  def handle_cast(_, %{ab_av1_path: :error} = state) do
    Logger.error("ab-av1 executable not found")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: :none} = state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{action: "scanning:start", video: video})
    args = ["crf-search"] ++ Helper.build_args(video.path, vmaf_percent, video)

    new_crf_searches = max(state.crf_searches - 1, 0)
    new_state = %{state | port: Helper.open_port(args), video: video, args: args, mode: :crf_search, crf_searches: new_crf_searches}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: port} = state) when port != :none do
    Logger.debug("Queueing crf search for video #{video.id}")
    new_queue = :queue.in({:crf_search, video, vmaf_percent}, state.queue)
    new_state = %{state | queue: new_queue, crf_searches: state.crf_searches + 1}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(
        {:encode, %Media.Vmaf{params: params} = vmaf},
        %{port: :none} = state
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

    new_encodes = max(state.encodes - 1, 0)
    new_state = %{state | port: Helper.open_port(args), video: vmaf.video, args: args, mode: :encode, encodes: new_encodes}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf}, %{port: port} = state) when port != :none do
    Logger.info("Queueing encode for video #{vmaf.video.id}")
    new_queue = :queue.in({:encode, vmaf}, state.queue)
    new_state = %{state | queue: new_queue, encodes: state.encodes + 1}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf, :insert_at_top}, %{port: :none} = state) do
    Logger.info("Inserting encode at top of queue for video #{vmaf.video.id}")
    args = [
      "encode",
      "--crf",
      to_string(vmaf.crf),
      "-o",
      Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
      "-i"
    ] ++ vmaf.params

    new_encodes = max(state.encodes - 1, 0)
    new_state = %{state | port: Helper.open_port(args), video: vmaf.video, args: args, mode: :encode, encodes: new_encodes}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf, :insert_at_top}, %{port: port} = state) when port != :none do
    Logger.info("Inserting encode at top of queue for video #{vmaf.video.id}")
    new_queue = :queue.in_r({:encode, vmaf}, state.queue)
    new_state = %{state | queue: new_queue, encodes: state.encodes + 1}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port, mode: :crf_search} = state) do
    vmafs =
      data
      |> String.split("\n", trim: true)
      |> Helper.parse_crf_search()
      |> Helper.attach_params(state.video, state.args)

    Enum.each(vmafs, fn vmaf ->
      Logger.debug("Parsed output: #{inspect(vmaf)}")

      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
        action: "scanning:progress",
        vmaf: Map.put(vmaf, "target_vmaf", state.args |> Enum.at(4))
      })
    end)

    {:noreply, %{state | last_vmaf: List.last(vmafs)}}
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
    case {exit_code, last_vmaf} do
      {0, last_vmaf} ->
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
          action: "scanning:finished",
          vmaf: Map.put(last_vmaf, "chosen", true) |> Map.put("target_vmaf", state.args |> Enum.at(3))
        })

      {_, _} ->
        Logger.error("CRF search failed with exit code #{exit_code}")
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
          action: "scanning:failed",
          reason: "No suitable CRF found"
        })
    end

    new_state = Helper.dequeue(queue, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, queue: queue, mode: :encode, video: video, args: args} = state
      ) do
    result =
      case exit_code do
        0 -> {:ok, :success}
        1 -> {:ok, :success}
        _ -> {:error, exit_code}
      end

    Logger.debug("Exit status: #{inspect(result)}")

    output_file = Enum.at(args, Enum.find_index(args, &(&1 == "-o")) + 1)

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
      action: "encoding:complete",
      result: result,
      video: video,
      output_file: output_file
    })

    new_state = Helper.dequeue(queue, state)
    {:noreply, new_state}
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

  @spec attach_params(list(map()), Media.Video.t(), list(String.t())) :: list(map())
  def attach_params(vmafs, video, args) do
    filtered_args = remove_args(args, ["crf-search", "--min-vmaf", "--temp-dir"])
    Enum.map(vmafs, &(Map.put(&1, "video_id", video.id) |> Map.put("params", filtered_args)))
  end

  @spec remove_args(list(String.t()), list(String.t())) :: list(String.t())
  def remove_args(args, keys) do
    Enum.reduce(args, {[], false}, fn
      _arg, {acc, true} ->
        {acc, false}

      arg, {acc, false} ->
        if Enum.member?(keys, arg), do: {acc, true}, else: {[arg | acc], false}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec build_rules(Media.Video.t()) :: list(String.t())
  def build_rules(video) do
    Rules.apply(video)
    |> Enum.reject(fn {k, _v} -> k == :"--acodec" end)
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
    if File.exists?(cwd_temp_dir), do: cwd_temp_dir, else: Path.join(System.tmp_dir!(), "ab-av1")
  end

  @spec update_encoding_progress(String.t(), map()) :: :ok
  def update_encoding_progress(data, state) do
    case Regex.named_captures(
           ~r/\[.*\] encoding (?<filename>\d+\.mkv)|(?<percent>\d+)%\s*,\s*(?<fps>\d+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours)/,
           data
         ) do

      %{"percent" => percent, "fps" => fps, "eta" => eta, "unit" => unit} when eta != "" ->
        Logger.info("Encoding progress: #{percent}%, #{fps} fps, ETA: #{eta} #{unit}")
        eta_seconds = convert_to_seconds(String.to_integer(eta), unit)
        human_readable_eta = "#{eta} #{unit}"

        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
          action: "encoding:progress",
          video: state.video,
          percent: String.to_integer(percent),
          fps: String.to_integer(fps),
          eta: eta_seconds,
          human_readable_eta: human_readable_eta
        })

      _ ->
        Logger.info("Encoding started for #{data}")
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
          action: "encoding:start",
          video: state.video,
        })
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

  @spec dequeue(:queue.queue(), map()) :: map()
  def dequeue(queue, state) do
    case :queue.out(queue) do
      {{:value, {:crf_search, video, vmaf_percent}}, new_queue} ->
        GenServer.cast(Reencodarr.AbAv1, {:crf_search, video, vmaf_percent})
        new_crf_searches = max(state.crf_searches - 1, 0)
        new_state = %{state | port: :none, queue: new_queue, last_vmaf: :none, mode: :none, crf_searches: new_crf_searches}
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
        new_state

      {{:value, {:encode, vmaf}}, new_queue} ->
        GenServer.cast(Reencodarr.AbAv1, {:encode, vmaf})
        new_encodes = max(state.encodes - 1, 0)
        new_state = %{state | port: :none, queue: new_queue, last_vmaf: :none, mode: :none, encodes: new_encodes}
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{action: "queue:update", crf_searches: new_state.crf_searches, encodes: new_state.encodes})
        new_state

      {:empty, _} ->
        %{state | port: :none, last_vmaf: :none, mode: :none}
    end
  end
end
