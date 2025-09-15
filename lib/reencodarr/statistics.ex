defmodule Reencodarr.Statistics do
  @moduledoc "Handles statistics and progress tracking for various operations."

  defstruct stats: %Reencodarr.Statistics.Stats{},
            encoding: false,
            crf_searching: false,
            encoding_progress: %Reencodarr.Statistics.EncodingProgress{
              filename: :none,
              percent: 0,
              eta: 0,
              fps: 0
            },
            crf_search_progress: %Reencodarr.Statistics.CrfSearchProgress{
              filename: :none,
              percent: 0,
              eta: 0,
              fps: 0,
              crf: 0,
              score: 0
            },
            syncing: false,
            sync_progress: 0,
            stats_update_in_progress: false,
            videos_by_estimated_percent: [],
            next_crf_search: []

  use GenServer
  require Logger
  alias Reencodarr.Media.{Statistics, VideoQueries}
  alias Reencodarr.Statistics.{CrfSearchProgress, EncodingProgress, Stats}

  @broadcast_interval 5_000

  # --- Public API ---

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get_stats do
    case Process.whereis(__MODULE__) do
      nil ->
        default_state()

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          GenServer.call(__MODULE__, :get_stats, 1000)
        else
          default_state()
        end
    end
  end

  # --- Private stats fetching functions ---

  defp fetch_comprehensive_stats do
    # Get base stats from Media.Statistics module
    base_stats = Statistics.fetch_media_stats()

    # Add queue-specific data
    %{
      base_stats
      | next_crf_search: get_videos_for_crf_search(10),
        videos_by_estimated_percent: list_videos_by_estimated_percent(10),
        next_analyzer: get_videos_needing_analysis(10)
    }
  end

  defp get_videos_for_crf_search(limit) do
    VideoQueries.videos_for_crf_search(limit)
  end

  defp list_videos_by_estimated_percent(limit) do
    VideoQueries.videos_ready_for_encoding(limit)
  end

  defp get_videos_needing_analysis(limit) do
    VideoQueries.videos_needing_analysis(limit)
  end

  defp default_state do
    %Reencodarr.Statistics{
      stats: %Stats{},
      encoding: false,
      crf_searching: false,
      syncing: false,
      sync_progress: 0,
      encoding_progress: %EncodingProgress{filename: :none, percent: 0, eta: 0, fps: 0},
      crf_search_progress: %CrfSearchProgress{
        filename: :none,
        percent: 0,
        eta: 0,
        fps: 0,
        crf: 0,
        score: 0
      },
      videos_by_estimated_percent: [],
      next_crf_search: []
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    subscribe_to_topics()

    state = %Reencodarr.Statistics{
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
      stats = fetch_comprehensive_stats()

      GenServer.cast(__MODULE__, {:update_stats, stats})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:broadcast_stats, %Reencodarr.Statistics{} = state) do
    if state.stats_update_in_progress do
      {:noreply, state}
    else
      new_state = %{state | stats_update_in_progress: true}

      start_task(fn ->
        stats = fetch_comprehensive_stats()
        GenServer.cast(__MODULE__, {:update_stats, stats})
        GenServer.cast(__MODULE__, :stats_update_complete)
      end)

      {:noreply, new_state}
    end
  end

  def handle_info(:broadcast_stats, state) do
    # Fallback clause for non-struct state
    {:noreply, state}
  end

  def handle_info({:progress_update, key, progress}, %Reencodarr.Statistics{} = state) do
    new_state = Map.put(state, key, progress)
    broadcast_state(new_state)
  end

  def handle_info({:sync, :started}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | syncing: true, sync_progress: 0}
    broadcast_state(new_state)
  end

  def handle_info({:sync, :progress, progress}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | sync_progress: progress}
    broadcast_state(new_state)
  end

  def handle_info({:sync, :complete}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | syncing: false, sync_progress: 0}
    broadcast_state(new_state)
  end

  def handle_info({:video_upserted, _video}, %Reencodarr.Statistics{} = state) do
    Task.start(fn ->
      stats = fetch_comprehensive_stats()
      GenServer.cast(__MODULE__, {:update_stats, stats})
    end)

    {:noreply, state}
  end

  # Handle state changes that affect statistics and dashboard queue counts
  def handle_info({:video_state_changed, video, new_state}, %Reencodarr.Statistics{} = state)
      when new_state in [:needs_analysis, :analyzed, :crf_searched, :encoded, :failed] do
    # These state changes affect queue counts and completion statistics
    Logger.debug("Statistics received video state change: #{video.path} -> #{new_state}")

    Task.start(fn ->
      stats = fetch_comprehensive_stats()
      GenServer.cast(__MODULE__, {:update_stats, stats})
    end)

    {:noreply, state}
  end

  # Ignore transient processing states that don't affect queue statistics
  def handle_info(
        {:video_state_changed, _video, processing_state},
        %Reencodarr.Statistics{} = state
      )
      when processing_state in [:crf_searching, :encoding] do
    # These are transient states - video is being actively processed
    # No need to refresh statistics as queue counts don't change
    {:noreply, state}
  end

  def handle_info({:vmaf_upserted, _vmaf}, %Reencodarr.Statistics{} = state) do
    Task.start(fn ->
      stats = fetch_comprehensive_stats()
      GenServer.cast(__MODULE__, {:update_stats, stats})
    end)

    {:noreply, state}
  end

  def handle_info({:crf_searcher, :started}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | crf_searching: true}
    broadcast_state(new_state)
  end

  def handle_info({:crf_searcher, :paused}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | crf_searching: false}
    broadcast_state(new_state)
  end

  def handle_info({:crf_search_progress, progress_update}, %Reencodarr.Statistics{} = state) do
    updated_crf_progress =
      determine_progress(state.crf_search_progress, progress_update)

    new_state = %{state | crf_search_progress: updated_crf_progress}
    broadcast_state(new_state)
  end

  def handle_info({:encoder, :started}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | encoding: true}
    broadcast_state(new_state)
  end

  def handle_info({:encoder, :paused}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | encoding: false}
    broadcast_state(new_state)
  end

  def handle_info({:encoder, :started, filename}, %Reencodarr.Statistics{} = state) do
    new_state = %{
      state
      | encoding: true,
        encoding_progress: %EncodingProgress{filename: filename, percent: 0, eta: 0, fps: 0}
    }

    broadcast_state(new_state)
  end

  def handle_info(
        {:encoder, :progress, %EncodingProgress{} = progress},
        %Reencodarr.Statistics{} = state
      ) do
    updated_encoding_progress =
      determine_progress(state.encoding_progress, progress)

    new_state = %{state | encoding_progress: updated_encoding_progress}
    broadcast_state(new_state)
  end

  def handle_info({:encoding_complete, _video}, %Reencodarr.Statistics{} = state) do
    new_state = %{
      state
      | encoding: false,
        encoding_progress: %EncodingProgress{filename: :none, percent: 0, eta: 0, fps: 0}
    }

    broadcast_state(new_state)
  end

  def handle_info({:encoding_complete, _video, _output_file}, %Reencodarr.Statistics{} = state) do
    # Update UI state - post-encoding cleanup is handled directly in AbAv1.Encode after broadcast
    new_state = %{
      state
      | encoding: false,
        encoding_progress: %EncodingProgress{filename: :none, percent: 0, eta: 0, fps: 0}
    }

    broadcast_state(new_state)
  end

  def handle_info({:encoder, :complete, _filename}, %Reencodarr.Statistics{} = state) do
    new_state = %{
      state
      | encoding: false,
        encoding_progress: %EncodingProgress{}
    }

    broadcast_state(new_state)
  end

  def handle_info({:encoder, :none}, %Reencodarr.Statistics{} = state) do
    new_state = %{
      state
      | encoding_progress: %EncodingProgress{
          filename: :none,
          percent: 0,
          eta: 0,
          fps: 0
        }
    }

    broadcast_state(new_state)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %Reencodarr.Statistics{} = state) do
    new_state = %{state | stats_update_in_progress: false}
    broadcast_state(new_state)
  end

  @impl true
  def handle_cast({:update_stats, stats}, %Reencodarr.Statistics{} = state) do
    new_state = %{
      state
      | stats: stats,
        next_crf_search: stats.next_crf_search,
        videos_by_estimated_percent: stats.videos_by_estimated_percent
    }

    broadcast_state(new_state)
  end

  def handle_cast(:stats_update_complete, %Reencodarr.Statistics{} = state) do
    new_state = %{state | stats_update_in_progress: false}
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, %Reencodarr.Statistics{} = state) do
    {:reply, state, state}
  end

  # --- Private Helpers ---

  defp determine_progress(current_progress, incoming_progress) do
    case {current_progress.filename, incoming_progress.filename} do
      # Reset case: incoming has :none filename
      {_, :none} ->
        reset_progress(incoming_progress.__struct__)

      # Same filename: merge progress
      {fname, fname} when is_binary(fname) ->
        merge_progress(current_progress, incoming_progress)

      # New filename: replace entirely
      {_, fname} when is_binary(fname) ->
        incoming_progress

      # Fallback: use incoming
      _ ->
        incoming_progress
    end
  end

  defp reset_progress(module_name) do
    struct(module_name, filename: :none)
  end

  defp merge_progress(current_progress, incoming_progress) do
    defaults = struct(current_progress.__struct__)

    changes_to_apply =
      incoming_progress
      |> Map.from_struct()
      |> Map.reject(&should_ignore_field?(&1, defaults))

    struct(current_progress, changes_to_apply)
  end

  defp should_ignore_field?({:filename, _}, _defaults), do: true
  defp should_ignore_field?({key, value}, defaults), do: value == Map.get(defaults, key)

  defp subscribe_to_topics do
    for topic <- [
          "progress",
          "encoder",
          "crf_searcher",
          "media_events",
          "video_state_transitions"
        ] do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, topic)
    end
  end

  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state})
    {:noreply, state}
  end

  defp start_task(task_fun) do
    Task.Supervisor.start_child(Reencodarr.TaskSupervisor, task_fun)
  end
end
