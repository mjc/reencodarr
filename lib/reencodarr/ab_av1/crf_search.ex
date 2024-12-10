defmodule Reencodarr.AbAv1.CrfSearch do
  use GenServer
  alias Reencodarr.{Media}
  alias Reencodarr.AbAv1.Helper
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    {:ok, %{port: :none, current_task: :none, last_vmaf: :none}}
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
    new_state = %{state | port: Helper.open_port(args), current_task: %{video: video}, last_vmaf: :none}
    {:noreply, new_state}
  end

  def handle_cast({:crf_search, video, _vmaf_percent}, state) do
    Logger.debug("CRF search already in progress for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port, current_task: %{video: video}} = state) do
    process_data(data, video, state)
  end

  @impl true
  def handle_info({port, {:data, {:noeol, data}}}, %{port: port, current_task: %{video: video}} = state) do
    Logger.error("Received partial data: for video: #{video.id}, #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_code}}, %{port: port, last_vmaf: last_vmaf} = state) do
    if exit_code == 0 and not is_nil(last_vmaf) do
      Logger.debug("CRF search finished successfully with last vmaf: #{inspect(last_vmaf)}")
      Media.mark_vmaf_as_chosen(last_vmaf)
    else
      Logger.error("CRF search failed with exit code #{exit_code}")
    end
    {:noreply, %{state | last_vmaf: :none, port: :none, current_task: :none}}
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

  defp process_data(data, video, state) do
    vmafs =
      data
      |> String.split("\n", trim: true)
      |> Helper.parse_crf_search()
      |> Helper.attach_params(video)

    Enum.each(vmafs, &Media.upsert_vmaf/1)
    {:noreply, %{state | last_vmaf: List.last(vmafs)}}
  end
end
