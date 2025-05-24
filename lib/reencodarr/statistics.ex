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
      determine_progress(state.crf_search_progress, progress_update)

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
    updated_encoding_progress =
      determine_progress(state.encoding_progress, progress)

    new_state = %State{state | encoding_progress: updated_encoding_progress}
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

  # Clause 1: Incoming update signals a reset (filename: :none)
  defp determine_progress(
         _current_progress,
         %{filename: :none, __struct__: module_name} = _incoming_progress
       ) do
    # Inlined reset_progress: Reset to default struct of the incoming type with filename: :none
    struct(module_name, filename: :none)
  end

  # Clause 2: Filenames match and are binary strings -> merge
  defp determine_progress(
         %{filename: fname, __struct__: module_name} = current_progress,
         %{filename: fname} = incoming_progress
       )
       when is_binary(fname) do
    # Inlined merge_progress:
    # Get defaults for the type of the current progress struct
    defaults = struct(module_name)

    changes_to_apply =
      incoming_progress
      |> Map.from_struct()
      |> Map.filter(fn {key, value} ->
        # Only apply if key is not :filename and value is different from its default
        key != :filename && value != Map.get(defaults, key)
      end)

    struct(current_progress, changes_to_apply)
  end

  # Clause 3: Incoming update has a new binary filename -> start new progress tracking
  defp determine_progress(
         # Current progress is not used as we are replacing it
         _current_progress,
         %{filename: update_fn} = incoming_progress
       )
       when is_binary(update_fn) do
    # Use the incoming progress struct as is
    incoming_progress
  end

  # Clause 4: Fallback -> use incoming progress as is
  # This covers any other cases, typically meaning the incoming_progress is taken as the new state.
  defp determine_progress(_current_progress, incoming_progress) do
    incoming_progress
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
