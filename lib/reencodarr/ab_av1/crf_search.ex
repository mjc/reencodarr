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
    \[
    (?<timestamp>[^\]]+)
    \]\s
    .*?
    crf\s
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
    (?:\s\(.*\))?
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
    (?:\s\(.*\))?
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
    .*?
    (?<progress>\d+(\.\d+)?)%,\s
    (?<fps>\d+(\.\d+)?)\sfps?,\s     # Updated to exclude "fps" from the capture group
    eta\s
    (?<eta>\d+\s(?:second|minute|hour|day|week|month|year)s?)
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
    {:ok, %{port: :none, current_task: :none, partial_line_buffer: ""}}
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
        %{port: port, current_task: %{video: video, args: args}, partial_line_buffer: buffer} = state
      ) do
    full_line = buffer <> line
    process_line(full_line, video, args)
    {:noreply, %{state | partial_line_buffer: ""}}
  end

  @impl true
  def handle_info(
        {port, {:data, {:noeol, data}}},
        %{port: port, current_task: %{video: video}, partial_line_buffer: buffer} = state
      ) do
    Logger.debug("Received partial data chunk for video #{video.id}, buffering.")
    new_buffer = buffer <> data
    {:noreply, %{state | partial_line_buffer: new_buffer}}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    if exit_code == 0 do
      Logger.debug("CRF search finished successfully")
    else
      Logger.error("CRF search failed with exit code #{exit_code}")
      Media.mark_as_failed(state.current_task.video)
    end

    GenServer.cast(Reencodarr.CrfSearcher, :crf_search_finished)

    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "progress",
      {:crf_search_progress, %CrfSearchProgress{filename: :none}}
    )

    {:noreply, %{state | port: :none, current_task: :none, partial_line_buffer: ""}}
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
  defp append_decimal_before_float(str) do
    str = if String.contains?(str, "."), do: str, else: str <> ".0"
    String.to_float(str)
  end

  defp process_line(line, video, args) do
    cond do
      handle_encoding_sample_line(line, video) ->
        :ok

      handle_vmaf_line(line, video, args) ->
        :ok

      handle_eta_vmaf_line(line, video, args) ->
        :ok

      handle_vmaf_comparison_line(line) ->
        :ok

      handle_progress_line(line, video) ->
        :ok

      handle_success_line(line, video) ->
        :ok

      handle_error_line(line, video) ->
        :ok

      true ->
        Logger.error("CrfSearch: No match for line: #{line}")
    end
  end

  defp handle_encoding_sample_line(line, video) do
    with captures when not is_nil(captures) <-
           Regex.named_captures(@encoding_sample_regex, line) do
      Logger.debug(
        "CrfSearch: Encoding sample #{captures["sample_num"]}/#{captures["total_samples"]}: #{captures["crf"]}"
      )

      broadcast_crf_search_progress(video.path, %CrfSearchProgress{
        filename: video.path,
        crf: captures["crf"]
      })

      true
    else
      _ -> false
    end
  end

  defp handle_vmaf_line(line, video, args) do
    with captures when not is_nil(captures) <-
           Regex.named_captures(@simple_vmaf_regex, line) ||
             Regex.named_captures(@sample_regex, line) do
      Logger.debug(
        "CrfSearch: CRF: #{captures["crf"]}, VMAF: #{captures["score"]}, Percent: #{captures["percent"]}%"
      )

      upsert_vmaf(Map.put(captures, "chosen", false), video, args)
      true
    else
      _ -> false
    end
  end

  defp handle_eta_vmaf_line(line, video, args) do
    with captures when not is_nil(captures) <- Regex.named_captures(@eta_vmaf_regex, line) do
      Logger.debug(
        "CrfSearch: CRF: #{captures["crf"]}, VMAF: #{captures["score"]}, size: #{captures["size"]} #{captures["unit"]}, Percent: #{captures["percent"]}%, time: #{captures["time"]} #{captures["time_unit"]}"
      )

      upsert_vmaf(Map.put(captures, "chosen", true), video, args)
      true
    else
      _ -> false
    end
  end

  defp handle_vmaf_comparison_line(line) do
    with captures when not is_nil(captures) <- Regex.named_captures(@vmaf_regex, line) do
      Logger.debug("VMAF comparison: #{captures["file1"]} vs #{captures["file2"]}")
      true
    else
      _ -> false
    end
  end

  defp handle_progress_line(line, video) do
    with captures when not is_nil(captures) <- Regex.named_captures(@progress_regex, line) do
      Logger.debug(
        "CrfSearch Progress: #{captures["progress"]}, FPS: #{captures["fps"]}, ETA: #{captures["eta"]}"
      )

      percent = append_decimal_before_float(captures["progress"])
      fps = append_decimal_before_float(captures["fps"])

      broadcast_crf_search_progress(video.path, %CrfSearchProgress{
        filename: video.path,
        percent: percent,
        eta: captures["eta"],
        fps: fps
      })

      true
    else
      _ -> false
    end
  end

  defp handle_success_line(line, video) do
    with captures when not is_nil(captures) <- Regex.named_captures(@success_line_regex, line) do
      Logger.info("CrfSearch successful for CRF: #{captures["crf"]}")
      Media.mark_vmaf_as_chosen(video.id, captures["crf"])
      true
    else
      _ -> false
    end
  end

  defp handle_error_line(line, video) do
    if line == "Error: Failed to find a suitable crf" do
      Logger.error("Failed to find a suitable CRF.")
      Media.mark_as_failed(video)
      true
    else
      false
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
      |> Enum.reject(fn
        # {"--enc-input", "hwaccel=cuda"} ->
        #   true

        {"--acodec", _v} ->
          true

        {"--enc", <<"b:a=", _::binary>>} ->
          true

        {"--enc", <<"ac=", _::binary>>} ->
          true

        {_k, _v} ->
          false
      end)
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
