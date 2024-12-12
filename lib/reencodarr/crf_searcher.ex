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
    {:ok, %{searching: false}}
  end

  def start do
    GenServer.cast(__MODULE__, :start_searching)
  end

  def pause do
    GenServer.cast(__MODULE__, :pause_searching)
  end

  def toggle_searching do
    GenServer.call(__MODULE__, :toggle_searching)
  end

  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  defp schedule_search do
    Logger.debug("Scheduling next check in 60 seconds...")
    # Schedule every 60 seconds
    Process.send_after(self(), :search_videos, 60_000)
  end

  @impl true
  def handle_cast(:start_searching, state) do
    Logger.debug("CRF searching started")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :started})
    {:noreply, Map.put(state, :searching, true)}
  end

  @impl true
  def handle_cast(:pause_searching, state) do
    Logger.debug("CRF searching paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :paused})
    {:noreply, Map.put(state, :searching, false)}
  end

  @impl true
  def handle_cast(:crf_search_finished, state) do
    Logger.info("Received notification that CRF search finished.")
    find_videos_without_vmafs()
    {:noreply, state}
  end

  @impl true
  def handle_call(:toggle_searching, _from, %{searching: true} = state) do
    Logger.debug("CRF searching paused")
    {:reply, :paused, Map.put(state, :searching, false)}
  end

  @impl true
  def handle_call(:toggle_searching, _from, %{searching: false} = state) do
    Logger.debug("CRF searching started")
    {:reply, :started, Map.put(state, :searching, true)}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, state.searching, state}
  end

  @impl true
  def handle_info(:search_videos, %{searching: true} = state) do
    Logger.info("Searching for videos without VMAFs...")
    find_videos_without_vmafs()
    schedule_search()
    {:noreply, state}
  end

  def handle_info(:search_videos, state) do
    schedule_search()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warning("AbAv1.CrfSearch process crashed or is not yet started.")
    # Retry monitoring after 10 seconds
    Process.send_after(self(), :monitor_crf_search, 10_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:monitor_crf_search, state) do
    case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
      nil ->
        Logger.error("CrfSearch process is not running.")
        # Retry monitoring after 10 seconds
        Process.send_after(self(), :monitor_crf_search, 10_000)

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
          Media.find_videos_without_vmafs(1)
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
