defmodule Reencodarr.AbAv1.CrfSearch do
  use GenServer
  alias Reencodarr.{Media}
  alias Reencodarr.AbAv1.Helper
  require Logger

  @encoding_sample_regex ~r/encoding sample (?<sample_num>\d+)\/(?<total_samples>\d+) crf (?<crf>\d+(\.\d+)?)/
  @simple_vmaf_regex ~r/^- crf (?<crf>\d+(\.\d+)?) VMAF (?<vmaf>\d+\.\d+) \(\d+%\)/
  @sample_regex ~r/sample (?<sample_num>\d+)\/(?<total_samples>\d+) crf (?<crf>\d+(\.\d+)?) VMAF (?<vmaf>\d+\.\d+) \(\d+%\)/
  @eta_vmaf_regex ~r/crf (?<crf>\d+(\.\d+)?) VMAF (?<vmaf>\d+\.\d+) predicted video stream size (?<size>\d+\.\d+) (?<unit>\w+) \(\d+%\) taking (?<time>\d+) (?<time_unit>seconds|minutes|hours)/
  @vmaf_regex ~r/vmaf (?<file1>.+?) vs reference (?<file2>.+)/
  @progress_regex ~r/\[.*\] (?<progress>\d+%)?, (?<fps>\d+ fps)?, eta (?<eta>\d+ seconds)/
  @success_line_regex ~r/\[.*\] crf (?<crf>\d+(\.\d+)?) successful/

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    {:ok, %{port: :none, current_task: :none}}
  end

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

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: :none} = state) do
    args = ["crf-search"] ++ Helper.build_args(video.path, vmaf_percent, video)

    new_state = %{
      state
      | port: Helper.open_port(args),
        current_task: %{video: video}
    }

    {:noreply, new_state}
  end

  def handle_cast({:crf_search, video, _vmaf_percent}, state) do
    Logger.error("CRF search already in progress for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:data, {:eol, line}}},
        %{port: port, current_task: %{video: video}} = state
      ) do
    process_line(line, video)
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
      Media.mark_as_reencoded(state.current_task.video)
    end

    {:noreply, %{state | port: :none, current_task: :none}}
  end

  @impl true
  def handle_info({:scanning_update, :progress, vmaf}, state) do
    Logger.debug("Received vmaf search progress")
    Media.upsert_vmaf(vmaf)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scanning_update, :finished, vmaf}, state) do
    Media.upsert_vmaf(vmaf)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scanning_update, :failed, reason}, state) do
    Logger.error("Scanning failed: #{reason}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:port_status, _from, %{port: port} = state) do
    status = if port == :none, do: :not_running, else: :running
    {:reply, status, state}
  end

  defp notify_crf_searcher do
    GenServer.cast(Reencodarr.CrfSearcher, :crf_search_finished)
  end

  def process_line(line, video) do
    cond do
      captures = Regex.named_captures(@encoding_sample_regex, line) ->
        Logger.info(
          "Encoding sample #{captures["sample_num"]}/#{captures["total_samples"]}: #{captures["crf"]}"
        )

        :none

      captures = Regex.named_captures(@simple_vmaf_regex, line) ->
        Logger.info("Simple VMAF: CRF: #{captures["crf"]}, VMAF: #{captures["vmaf"]}")

        upsert_vmaf(Map.put(captures, "chosen", false), video)

      captures = Regex.named_captures(@sample_regex, line) ->
        Logger.info(
          "Sample #{captures["sample_num"]}/#{captures["total_samples"]} - CRF: #{captures["crf"]}, VMAF: #{captures["vmaf"]}"
        )

        upsert_vmaf(Map.put(captures, "chosen", false), video)

      captures = Regex.named_captures(@eta_vmaf_regex, line) ->
        Logger.info(
          "VMAF: CRF: #{captures["crf"]}, VMAF: #{captures["vmaf"]}, size: #{captures["size"]} #{captures["unit"]}, time: #{captures["time"]} #{captures["time_unit"]}"
        )

        upsert_vmaf(Map.put(captures, "chosen", true), video)

      captures = Regex.named_captures(@vmaf_regex, line) ->
        Logger.info("VMAF comparison: #{captures["file1"]} vs #{captures["file2"]}")
        :none

      captures = Regex.named_captures(@progress_regex, line) ->
        Logger.info(
          "Progress: #{captures["progress"]}, FPS: #{captures["fps"]}, ETA: #{captures["eta"]}"
        )

        :none

      captures = Regex.named_captures(@success_line_regex, line) ->
        Logger.info("CRF search successful for CRF: #{captures["crf"]}")
        Media.mark_vmaf_as_chosen(video.id, captures["crf"])
        :none

      line == "Error: Failed to find a suitable crf" ->
        Logger.error("Failed to find a suitable CRF")
        Media.mark_as_reencoded(video)
        :none

      true ->
        Logger.error("No match for line: #{line}")
        :none
    end
  end

  defp upsert_vmaf(%{"crf" => crf, "vmaf" => vmaf, "chosen" => chosen} = params, video) do
    time = parse_time(params["time"], params["time_unit"])

    vmaf_data = %{
      video_id: video.id,
      crf: crf,
      vmaf: 95,
      chosen: chosen,
      score: vmaf,
      percent: vmaf,
      params: ["example_param=example_value"],
      time: time
    }

    case Media.upsert_vmaf(vmaf_data) do
      {:ok, created_vmaf} ->
        Logger.debug("Upserted VMAF: #{inspect(created_vmaf)}")
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:progress, created_vmaf})
        created_vmaf

      {:error, changeset} ->
        Logger.error("Failed to upsert VMAF: #{inspect(changeset)}")
        :none
    end
  end

  defp parse_time(nil, _), do: nil
  defp parse_time(_, nil), do: nil

  defp parse_time(time, time_unit) do
    case Integer.parse(time) do
      {time_value, _} ->
        convert_to_seconds(time_value, time_unit)

      :error ->
        nil
    end
  end

  defp convert_to_seconds(time, "minutes"), do: time * 60
  defp convert_to_seconds(time, "hours"), do: time * 3600
  defp convert_to_seconds(time, "seconds"), do: time
  defp convert_to_seconds(time, "days"), do: time * 86400
  defp convert_to_seconds(time, "weeks"), do: time * 604_800
  defp convert_to_seconds(time, "months"), do: time * 2_628_000
  defp convert_to_seconds(time, "years"), do: time * 31_536_000
end
