defmodule Reencodarr.CrfSearcher do
  use GenServer

  alias Reencodarr.Media
  alias Reencodarr.AbAv1
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    Logger.debug("Starting CrfSearcher...")
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Logger.debug("Initializing CrfSearcher...")
    Process.monitor(GenServer.whereis(Reencodarr.AbAv1.CrfSearch))
    schedule_search()
    {:ok, %{}}
  end

  defp schedule_search do
    Logger.debug("Scheduling next search in 60 seconds...")
    Process.send_after(self(), :search_videos, 60_000) # Schedule every 60 seconds
  end

  @impl true
  def handle_info(:search_videos, state) do
    Logger.debug("Searching for videos without VMAFs...")
    find_videos_without_vmafs()
    schedule_search()
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
    |> Enum.each(fn video ->
      Logger.debug("Calling AbAv1.crf_search for video: #{video.id}")
      AbAv1.crf_search(video)
    end)
  end
end
