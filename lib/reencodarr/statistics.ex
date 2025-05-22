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
  def handle_info({:vmaf_upserted, _vmaf}, %State{} = state) do
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
  def handle_info({:crf_searcher, :paused}, %State{} = state) do
    new_state = %State{state | crf_searching: false}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:crf_search_progress, progress_update}, %State{} = state) do
    updated_crf_progress =
      determine_crf_progress(state.crf_search_progress, progress_update)

    new_state = %State{state | crf_search_progress: updated_crf_progress}
    broadcast_state(new_state)
  end

  @impl true
  def handle_info({:encoder, :started, filename}, %State{} = state) do
    new_state = %State{
      state
      | encoding: true,
        encoding_progress: %EncodingProgress{filename: filename, percent: 0, eta: 0, fps: 0}
    }

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
  def handle_info({:encoder, :paused}, %State{} = state) do
    new_state = %State{state | encoding: false}
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

  # Clause 1: Explicit reset signal from progress_update
  defp determine_crf_progress(_current_progress, %CrfSearchProgress{filename: :none}) do
    reset_crf_progress()
  end

  # Clause 2: Same valid (string) filename, merge progress
  defp determine_crf_progress(
         %CrfSearchProgress{filename: fname} = current_progress,
         %CrfSearchProgress{filename: fname} = progress_update
       )
       when is_binary(fname) do
    merge_crf_progress(current_progress, progress_update)
  end

  # Clause 3: New valid (string) filename in progress_update (different from current, or current was nil/:none)
  defp determine_crf_progress(
         # current_progress.filename is not a string matching update_fn, or was nil/:none
         _current_progress,
         %CrfSearchProgress{filename: update_fn} = progress_update
       )
       when is_binary(update_fn) do
    # This is effectively starting new progress
    progress_update
  end

  # Clause 4: Fallback (e.g., progress_update.filename is nil)
  # This handles cases where progress_update.filename is not :none and not a binary string.
  defp determine_crf_progress(_current_progress, progress_update) do
    progress_update
  end

  defp reset_crf_progress do
    %Reencodarr.Statistics.CrfSearchProgress{filename: :none}
  end

  defp merge_crf_progress(current_progress, progress_update) do
    # Defaults instantiated locally
    defaults = %Reencodarr.Statistics.CrfSearchProgress{}

    changes_to_apply =
      progress_update
      |> Map.from_struct()
      |> Map.filter(fn {key, value} ->
        key != :filename && value != Map.get(defaults, key)
      end)

    struct(current_progress, changes_to_apply)
  end

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
