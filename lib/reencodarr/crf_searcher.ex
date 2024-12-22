defmodule Reencodarr.CrfSearcher do
  use GenServer

  alias Reencodarr.{Media, AbAv1}
  require Logger

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    Logger.info("Starting CrfSearcher...")
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def start, do: GenServer.cast(__MODULE__, :start_searching)
  def pause, do: GenServer.cast(__MODULE__, :pause_searching)
  def scanning?, do: GenServer.call(__MODULE__, :scanning?)

  # GenServer Callbacks
  @impl true
  def init(:ok) do
    Logger.info("Initializing CrfSearcher...")
    monitor_crf_search()
    {:ok, %{searching: false}}
  end

  @impl true
  def handle_cast(:start_searching, state) do
    Logger.debug("CRF searching started")
    monitor_crf_search()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :started})
    find_videos_without_vmafs()
    {:noreply, %{state | searching: true}}
  end

  @impl true
  def handle_cast(:pause_searching, state) do
    Logger.debug("CRF searching paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :paused})
    {:noreply, %{state | searching: false}}
  end

  @impl true
  def handle_cast(:crf_search_finished, %{searching: true} = state) do
    Logger.info("Received notification that CRF search finished.")
    find_videos_without_vmafs()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:crf_search_finished, %{searching: false} = state) do
    Logger.info("CRF search is paused, not searching next items.")
    {:noreply, state}
  end

  @impl true
  def handle_call(:scanning?, _from, %{searching: searching} = state) do
    {:reply, searching, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warning("AbAv1.CrfSearch process crashed or is not yet started.")
    Process.send_after(self(), :monitor_crf_search, 10_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:monitor_crf_search, state) do
    monitor_crf_search()
    {:noreply, state}
  end

  # Private Helper Functions
  defp monitor_crf_search do
    case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
      nil ->
        Logger.error("CrfSearch process is not running.")
        Process.send_after(self(), :monitor_crf_search, 10_000)

      pid ->
        Process.monitor(pid)
    end
  end

  defp find_videos_without_vmafs do
    with pid when not is_nil(pid) <- GenServer.whereis(Reencodarr.AbAv1.CrfSearch),
         false <- AbAv1.CrfSearch.running?(),
         videos when not is_nil(videos) <- Media.find_videos_without_vmafs(1) do
      Enum.each(videos, fn video ->
        Logger.info("Calling AbAv1.crf_search for video: #{video.id}")
        AbAv1.crf_search(video)
      end)
    else
      nil -> Logger.error("CrfSearch process is not running.")
      true -> Logger.info("CRF search is already in progress, skipping search for new videos.")
      _ -> Logger.error("No videos found without VMAFs")
    end
  end
end
