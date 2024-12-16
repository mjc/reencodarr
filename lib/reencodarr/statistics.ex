defmodule Reencodarr.Statistics do
  use GenServer
  alias Reencodarr.{Media, Encoder, CrfSearcher}

  require Logger

  @update_interval 5_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "progress")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")

    initial_state = %{
      stats: Media.fetch_stats(),
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      syncing: false,
      sync_progress: 0,
      crf_search_progress: %Media.Vmaf{},
      encoding_progress: %{}
    }

    schedule_update()
    {:ok, initial_state}
  end

  @impl true
  def handle_info(:update_stats, state) do
    new_stats = fetch_all_stats(state)
    Logger.debug("Updating stats: #{inspect(new_stats)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_stats})
    schedule_update()
    {:noreply, new_stats}
  end

  @impl true
  def handle_info({:progress, vmaf}, state) do
    new_state = %{state | crf_search_progress: vmaf}
    Logger.debug("Received progress: #{inspect(vmaf)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, state) do
    new_state = %{state | encoding_progress: %{percent: percent, eta: eta, fps: fps}}
    Logger.debug("Encoding progress: #{inspect(new_state)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoder, :started}, state) do
    new_state = %{state | encoding: true}
    Logger.debug("Encoder started")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoder, :paused}, state) do
    new_state = %{state | encoding: false}
    Logger.debug("Encoder paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:sync_progress, progress}, state) do
    new_state = %{state | sync_progress: progress}
    Logger.debug("Sync progress: #{inspect(progress)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:sync_complete, state) do
    new_state = %{state | syncing: false, sync_progress: 0}
    Logger.info("Sync complete")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  defp schedule_update do
    Process.send_after(self(), :update_stats, @update_interval)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state, state}
  end

  defp fetch_all_stats(state) do
    new_stats = %{
      stats: Media.fetch_stats(),
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?()
    }

    Map.merge(state, new_stats)
  end
end
