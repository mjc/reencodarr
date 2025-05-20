defmodule Reencodarr.Statistics do
  use GenServer
  alias Reencodarr.Media
  alias Reencodarr.Statistics.{EncodingProgress, CrfSearchProgress, Stats, State}
  require Logger

  @broadcast_interval 5_000

  # --- Public API ---

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    subscribe_to_topics()

    state = %State{
      stats: %Stats{},
      encoding: false,
      crf_searching: false,
      syncing: false,
      sync_progress: 0,
      crf_search_progress: %CrfSearchProgress{},
      encoding_progress: %EncodingProgress{}
    }

    :timer.send_interval(@broadcast_interval, :broadcast_stats)
    {:ok, state, {:continue, :fetch_initial_stats}}
  end

  @impl true
  def handle_continue(:fetch_initial_stats, state) do
    Task.start(fn ->
      stats = Media.fetch_stats()
      GenServer.cast(__MODULE__, {:update_stats, stats})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:broadcast_stats, %State{} = state) do
    if state.stats_update_in_progress do
      Logger.info("Stats update already in progress, skipping new update.")
      {:noreply, state}
    else
      new_state = %State{state | stats_update_in_progress: true}
      Task.start(fn ->
        stats = Media.fetch_stats()
        GenServer.cast(__MODULE__, {:update_stats, stats})
        GenServer.cast(__MODULE__, :stats_update_complete)
      end)

      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:progress_update, key, progress}, %State{} = state) do
    new_state = Map.put(state, key, progress)
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:sync, :started}, %State{} = state) do
    new_state = %State{state | syncing: true, sync_progress: 0}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:sync, :progress, progress}, %State{} = state) do
    new_state = %State{state | sync_progress: progress}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:sync, :complete}, %State{} = state) do
    new_state = %State{state | syncing: false, sync_progress: 0}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:video_upserted, _video}, %State{} = state) do
    Task.start(fn ->
      stats = Media.fetch_stats()
      GenServer.cast(__MODULE__, {:update_stats, stats})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_searcher, :started}, %State{} = state) do
    new_state = %State{state | crf_searching: true}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:crf_search_progress, progress}, %State{} = state) do
    new_state = %State{state | crf_search_progress: progress}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:encoder, :started, filename}, %State{} = state) do
    new_state = %State{state | encoding: true, encoding_progress: %EncodingProgress{filename: filename, percent: 0, eta: 0, fps: 0}}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:encoder, :progress, %EncodingProgress{} = progress}, %State{} = state) do
    new_state = %State{state | encoding_progress: progress}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:encoder, :complete, _filename}, %State{} = state) do
    new_state = %State{state | encoding: false, encoding_progress: %EncodingProgress{}}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:encoder, :none}, %State{} = state) do
    # No encoding currently active, ignore
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_stats, stats}, %State{} = state) do
    new_state = %State{state | stats: stats}
    broadcast_state(new_state)
  end

  @impl true
  def handle_cast(:stats_update_complete, %State{} = state) do
    new_state = %State{state | stats_update_in_progress: false}
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, %State{} = state) do
    {:reply, state, state}
  end

  # --- Private Helpers ---

  defp subscribe_to_topics do
    for topic <- ["progress", "encoder", "crf_searcher", "media_events"] do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, topic)
    end
  end

  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state})
    {:noreply, state}
  end
end
