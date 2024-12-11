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
    Logger.info("Scheduling next search in 60 seconds...")
    Process.send_after(self(), :search_videos, 60_000) # Schedule every 60 seconds
  end

  @impl true
  def handle_info(:search_videos, state) do
    Logger.info("Searching for videos without VMAFs...")
    find_videos_without_vmafs()
    schedule_search()
    {:noreply, state}
  end

  @impl true
  def handle_info(:crf_search_finished, state) do
    Logger.info("Received notification that CRF search finished.")
    find_videos_without_vmafs()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warning("AbAv1.CrfSearch process crashed. Searching for videos without VMAFs...")
    find_videos_without_vmafs()
    Process.monitor(GenServer.whereis(Reencodarr.AbAv1.CrfSearch))
    {:noreply, state}
  end

  defp find_videos_without_vmafs do
    Media.list_videos()
    |> Enum.filter(fn video -> not Media.video_has_vmafs?(video) end)
    |> Enum.take(1) # Take only the next video
    |> Enum.each(fn video ->
      Logger.info("Calling AbAv1.crf_search for video: #{video.id}")
      AbAv1.crf_search(video)
    end)
  end
end
