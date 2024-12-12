defmodule Reencodarr.CrfSearcher do
  use GenServer

  alias Reencodarr.Media
  alias Reencodarr.AbAv1
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    Logger.info("Starting CrfSearcher...")
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Logger.info("Initializing CrfSearcher...")
    Process.monitor(GenServer.whereis(Reencodarr.AbAv1.CrfSearch))
    schedule_search()
    {:ok, %{}}
  end

  defp schedule_search do
    Logger.debug("Scheduling next check in 60 seconds...")
    Process.send_after(self(), :search_videos, 60_000) # Schedule every 60 seconds
  end


  @impl true
  def handle_cast(:crf_search_finished, state) do
    Logger.info("Received notification that CRF search finished.")
    find_videos_without_vmafs()
    {:noreply, state}
  end

  @impl true
  def handle_info(:search_videos, state) do
    Logger.info("Searching for videos without VMAFs...")
    find_videos_without_vmafs()
    schedule_search()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warning("AbAv1.CrfSearch process crashed or is not yet started.")
    Process.send_after(self(), :monitor_crf_search, 10_000) # Retry monitoring after 10 seconds
    {:noreply, state}
  end

  @impl true
  def handle_info(:monitor_crf_search, state) do
    case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
      nil ->
        Logger.error("CrfSearch process is not running.")
        Process.send_after(self(), :monitor_crf_search, 10_000) # Retry monitoring after 10 seconds
      _pid ->
        Process.monitor(GenServer.whereis(Reencodarr.AbAv1.CrfSearch))
    end
    {:noreply, state}
  end

  defp find_videos_without_vmafs do
    case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
      nil ->
        Logger.error("CrfSearch process is not running.")
      _pid ->
        if GenServer.call(Reencodarr.AbAv1.CrfSearch, :port_status) == :not_running do
          Media.list_videos()
          |> Enum.filter(fn video -> not Media.video_has_vmafs?(video) end)
          # Take only the next video
          |> Enum.take(1)
          |> Enum.each(fn video ->
            Logger.info("Calling AbAv1.crf_search for video: #{video.id}")
            AbAv1.crf_search(video)
          end)
        else
          Logger.info("CRF search is already in progress, skipping search for new videos.")
        end
    end
  end
end
