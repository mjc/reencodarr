defmodule Reencodarr.AbAv1.CrfSearch do
  use GenServer
  alias Reencodarr.{Media, AbAv1.Helper, Statistics.CrfSearchProgress}
  require Logger

  @encoding_sample_regex ~r/
    # I plan on making a chart for these. input file would be helpful, as well as target vmaf.
    encoding\ssample\s
    (?<sample_num>\d+)\/             # Capture sample number
    (?<total_samples>\d+)\s          # Capture total samples
    crf\s
    (?<crf>\d+(\.\d+)?)              # Capture CRF value
  /x

  @simple_vmaf_regex ~r/
    ^-\scrf\s
    (?<crf>\d+(\.\d+)?)\s            # Capture CRF value
    VMAF\s
    (?<score>\d+\.\d+)\s             # Capture VMAF score
    \((?<percent>\d+)%\)             # Capture percentage
  /x

  @sample_regex ~r/
    sample\s
    (?<sample_num>\d+)\/             # Capture sample number
    (?<total_samples>\d+)\s          # Capture total samples
    crf\s
    (?<crf>\d+(\.\d+)?)\s            # Capture CRF value
    VMAF\s
    (?<score>\d+\.\d+)\s             # Capture VMAF score
    \((?<percent>\d+)%\)             # Capture percentage
  /x

  @eta_vmaf_regex ~r/
    # It would be helpful to have the input path here
    crf\s
    (?<crf>\d+(\.\d+)?)\s            # Capture CRF value
    VMAF\s
    (?<score>\d+\.\d+)\s             # Capture VMAF score
    predicted\svideo\sstream\ssize\s
    (?<size>\d+\.\d+)\s              # Capture size
    (?<unit>\w+)\s                   # Capture unit
    \((?<percent>\d+)%\)\s           # Capture percentage
    taking\s
    (?<time>\d+)\s                   # Capture time
    (?<time_unit>second|minute|hour|day|week|month|year)s? # Capture time unit with optional plural
  /x

  @vmaf_regex ~r/
    # currently I parse a bunch of stuff out of the filenames here.
    vmaf\s
    (?<file1>.+?)\s                  # Capture first file name
    vs\sreference\s
    (?<file2>.+)                     # Capture second file name
  /x

  @progress_regex ~r/
    \[
    (?<timestamp>[^\]]+)
    \]\s
    (?<level>[A-Z]+)\s
    (?<module>[^\s]+)::(?<function>[^\s]+)\]\s
    (?<progress>\d+(\.\d+)%)?,\s
    (?<fps>\d+(\.\d+)?\sfps)?,\s
    eta\s
    (?<eta>\d+\s(?:second|minute|hour|day|week|month|year)s?) # Capture time unit with optional plural
  /x

  @success_line_regex ~r/
    # It would be helpful to have the path, target vmaf, percentage, vmaf score, time taken, and path in here.
    \[.*\]\s
    crf\s
    (?<crf>\d+(\.\d+)?)\s            # Capture CRF value from this one to know which CRF was selected.
    successful
  /x

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(%Media.Video{reencoded: true, path: path}, _vmaf_percent) do
    Logger.debug("Skipping crf search for video #{path} as it is already reencoded")
    :ok
  end

  def crf_search(%Media.Video{} = video, vmaf_percent) do
    if Media.chosen_vmaf_exists?(video) do
      Logger.debug("Skipping crf search for video #{video.path} as a chosen VMAF already exists")
    else
      Logger.info("Initiating crf search for video #{video.id}")
      GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
    end

    :ok
  end

  def running? do
    GenServer.call(__MODULE__, :running?) == :running
  end

  # GenServer callbacks
  @impl true
  def init(:ok) do
    {:ok, %{port: :none, current_task: :none}}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: :none} = state) do
    args = build_crf_search_args(video, vmaf_percent)
    new_state = %{state | port: Helper.open_port(args), current_task: %{video: video, args: args}}
    {:noreply, new_state}
  end

  def handle_cast({:crf_search, video, _vmaf_percent}, state) do
    Logger.error("CRF search already in progress for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:data, {:eol, line}}},
        %{port: port, current_task: %{video: video, args: args}} = state
      ) do
    process_line(line, video, args)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:data, {:noeol, data}}},
        %{port: port, current_task: %{video: video}} = state
      ) do
    Logger.error("Received partial data: for video: #{video.id}, #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    if exit_code == 0 do
      Logger.debug("CRF search finished successfully")
      notify_crf_searcher()
    else
      Logger.error("CRF search failed with exit code #{exit_code}")
      Media.mark_as_failed(state.current_task.video)
    end

    {:noreply, %{state | port: :none, current_task: :none}}
  end

  @impl true
  def handle_info({:scanning_update, status, data}, state) do
    case status do
      :progress ->
        Logger.debug("Received vmaf search progress")
        Media.upsert_vmaf(data)

      :finished ->
        Media.upsert_vmaf(data)

      :failed ->
        Logger.error("Scanning failed: #{data}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:running?, _from, %{port: port} = state) do
    status = if port == :none, do: :not_running, else: :running
    {:reply, status, state}
  end

  # Private helper functions
  defp notify_crf_searcher do
    GenServer.cast(Reencodarr.CrfSearcher, :crf_search_finished)
  end

  defp process_line(line, video, args) do
    cond do
      captures = Regex.named_captures(@encoding_sample_regex, line) ->
        Logger.info(
          "CrfSearch: Encoding sample #{captures["sample_num"]}/#{captures["total_samples"]}: #{captures["crf"]}"
        )

        broadcast_crf_search_progress(video.path, %CrfSearchProgress{
          filename: video.path,
          crf: captures["crf"]
        })

      captures = Regex.named_captures(@simple_vmaf_regex, line) ||
                 Regex.named_captures(@sample_regex, line) ->
        Logger.info(
          "CrfSearch: CRF: #{captures["crf"]}, VMAF: #{captures["score"]}, Percent: #{captures["percent"]}%"
        )
        upsert_vmaf(Map.put(captures, "chosen", false), video, args)

      captures = Regex.named_captures(@eta_vmaf_regex, line) ->
        Logger.info(
          "CrfSearch: CRF: #{captures["crf"]}, VMAF: #{captures["vmaf"]}, size: #{captures["size"]} #{captures["unit"]}, Percent: #{captures["percent"]}%, time: #{captures["time"]} #{captures["time_unit"]}"
        )

        upsert_vmaf(Map.put(captures, "chosen", true), video, args)

      captures = Regex.named_captures(@vmaf_regex, line) ->
        Logger.debug("VMAF comparison: #{captures["file1"]} vs #{captures["file2"]}")

      captures = Regex.named_captures(@progress_regex, line) ->
        Logger.info(
          "CrfSearch Progress: #{captures["progress"]}, FPS: #{captures["fps"]}, ETA: #{captures["eta"]}"
        )

        broadcast_crf_search_progress(video.path, %CrfSearchProgress{
          filename: video.path,
          percent: String.to_float(captures["progress"]),
          eta: captures["eta"],
          fps: String.to_float(captures["fps"])
        })

      captures = Regex.named_captures(@success_line_regex, line) ->
        Logger.info("CrfSearch successful for CRF: #{captures["crf"]}")
        Media.mark_vmaf_as_chosen(video.id, captures["crf"])

      line == "Error: Failed to find a suitable crf" ->
        Logger.error("Failed to find a suitable CRF.")
        Media.mark_as_failed(video)

      true ->
        Logger.error("CrfSearch: No match for line: #{line}")
    end
  end

  defp build_crf_search_args(video, vmaf_percent) do
    base_args = [
      "crf-search",
      "-i",
      video.path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      Helper.temp_dir()
    ]

    rule_args =
      video
      |> Reencodarr.Rules.apply()
      |> Enum.reject(fn {k, _v} -> k == "--acodec" end)
      |> Enum.flat_map(fn {k, v} -> [to_string(k), to_string(v)] end)

    base_args ++ rule_args
  end

  defp upsert_vmaf(params, video, args) do
    time = parse_time(params["time"], params["time_unit"])

    vmaf_data =
      Map.merge(params, %{
        "video_id" => video.id,
        "params" => Helper.remove_args(args, ["--min-vmaf", "crf-search"]),
        "time" => time,
        "size" => "#{params["size"]} #{params["unit"]}",
        "target" => 95
      })

    case Media.upsert_vmaf(vmaf_data) do
      {:ok, created_vmaf} ->
        Logger.debug("Upserted VMAF: #{inspect(created_vmaf)}")
        broadcast_crf_search_progress(video.path, created_vmaf)
        created_vmaf

      {:error, changeset} ->
        Logger.error("Failed to upsert VMAF: #{inspect(changeset)}")
    end
  end

  defp broadcast_crf_search_progress(video_path, vmaf) do
    filename = Path.basename(video_path)

    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "progress",
      {:crf_search_progress,
       %CrfSearchProgress{
         filename: filename,
         percent: vmaf.percent,
         crf: vmaf.crf,
         score: vmaf.score
       }}
    )
  end

  defp parse_time(nil, _), do: nil
  defp parse_time(_, nil), do: nil

  defp parse_time(time, time_unit) do
    case Integer.parse(time) do
      {time_value, _} -> Helper.convert_to_seconds(time_value, time_unit)
      :error -> nil
    end
  end
end
