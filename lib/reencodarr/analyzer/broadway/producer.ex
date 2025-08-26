defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway producer for analyzer operations.

  This producer dispatches videos for analysis in batches of up to 5,
  managing demand and batch processing for optimal mediainfo usage.
  """

  use GenStage
  require Logger
  alias Reencodarr.Analyzer.QueueManager
  alias Reencodarr.{Media, Telemetry}

  @broadway_name Reencodarr.Analyzer.Broadway

  defmodule State do
    @moduledoc false
    defstruct [
      :demand,
      :status,
      :queue,
      :manual_queue,
      :paused,
      :processing
    ]

    def update(state, updates) when is_struct(state, __MODULE__) do
      struct(state, updates)
    end

    def update(state, updates) when is_map(state) do
      # Handle case where state is a plain map (e.g., after crash/restart)
      # Convert it to a proper State struct first
      state_struct = struct(__MODULE__, state)
      struct(state_struct, updates)
    end
  end

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API for external control
  def pause, do: send_to_producer(:pause)
  def resume, do: send_to_producer(:resume)
  def dispatch_available, do: send_to_producer(:dispatch_available)
  def add_video(video_info), do: send_to_producer({:add_video, video_info})

  # Alias for API compatibility
  def start, do: resume()

  def running? do
    case find_producer_process() do
      nil ->
        false

      producer_pid ->
        try do
          GenStage.call(producer_pid, :running?, 1000)
        catch
          :exit, _ -> false
        end
    end
  end

  def actively_running? do
    case find_producer_process() do
      nil ->
        false

      producer_pid ->
        try do
          GenStage.call(producer_pid, :actively_running?, 1000)
        catch
          :exit, _ -> false
        end
    end
  end

  @impl GenStage
  def init(_opts) do
    # Subscribe to media events for new videos
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to analyzer events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer_events")

    # Send a delayed message to trigger initial dispatch
    Process.send_after(self(), :initial_dispatch, 1000)

    {:producer,
     %State{
       demand: 0,
       status: :paused,
       queue: :queue.new(),
       manual_queue: []
     }}
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    # Button should reflect user intent - not running if paused or pausing
    running = state.status == :running
    {:reply, running, [], state}
  end

  @impl GenStage
  def handle_call(:actively_running?, _from, state) do
    # For telemetry/progress - actively running if processing or pausing
    # This allows progress to continue during pausing state
    actively_running = state.status in [:processing, :pausing]
    {:reply, actively_running, [], state}
  end

  @impl GenStage
  def handle_call(:get_state, _from, state) do
    {:reply, state, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    case state.status do
      :processing ->
        Logger.info("Analyzer pausing - will finish current batch and stop")
        {:noreply, [], State.update(state, status: :pausing)}

      _ ->
        Logger.info("Analyzer paused")
        Telemetry.emit_analyzer_paused()
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
        :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})
        {:noreply, [], State.update(state, status: :paused)}
    end
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("Analyzer resumed")
    Telemetry.emit_analyzer_started()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :started})
    :telemetry.execute([:reencodarr, :analyzer, :started], %{}, %{})
    new_state = State.update(state, status: :running)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast({:add_video, video_info}, state) do
    Logger.info("Adding video to Broadway queue: #{video_info.path}")
    Logger.info("Video info being added: #{inspect(video_info)}")

    Logger.debug(
      "Current state - demand: #{state.demand}, status: #{state.status}, queue size: #{length(state.manual_queue)}"
    )

    new_manual_queue = [video_info | state.manual_queue]
    new_state = State.update(state, manual_queue: new_manual_queue)
    Logger.debug("After adding - queue size: #{length(new_state.manual_queue)}")

    # Broadcast queue state change
    broadcast_queue_state(new_state.manual_queue)

    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    # Trigger dispatch to check for videos that need analysis
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    Logger.debug("Broadway producer received demand for #{demand} items")
    new_state = State.update(state, demand: state.demand + demand)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info({:video_upserted, _video}, state) do
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info({:analysis_completed, _path, _result}, state) do
    # Individual analysis completed - this is handled by batch completion now
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:batch_analysis_completed, _batch_size}, state) do
    # Batch analysis completed
    Logger.debug("Producer: Received batch analysis completion notification")

    case state.status do
      :pausing ->
        Logger.info("Analyzer finished current batch - now fully paused")
        Telemetry.emit_analyzer_paused()
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
        :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})
        new_state = State.update(state, status: :paused)
        {:noreply, [], new_state}

      _ ->
        new_state = State.update(state, status: :running)
        dispatch_if_ready(new_state)
    end
  end

  @impl GenStage
  def handle_info(:initial_dispatch, state) do
    # Trigger initial dispatch after startup to check for videos needing analysis
    Logger.debug("Producer: Initial dispatch triggered")
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # Private functions

  defp send_to_producer(message) do
    case find_producer_process() do
      nil -> {:error, :producer_not_found}
      producer_pid -> GenStage.cast(producer_pid, message)
    end
  end

  defp find_producer_process do
    producer_supervisor_name = :"#{@broadway_name}.Broadway.ProducerSupervisor"

    with pid when is_pid(pid) <- Process.whereis(producer_supervisor_name),
         children <- Supervisor.which_children(pid),
         producer_pid when is_pid(producer_pid) <- find_actual_producer(children) do
      producer_pid
    else
      _ -> nil
    end
  end

  defp find_actual_producer(children) do
    Enum.find_value(children, fn {_id, pid, _type, _modules} ->
      if is_pid(pid) do
        try do
          GenStage.call(pid, :running?, 1000)
          pid
        catch
          :exit, _ -> nil
        end
      end
    end)
  end

  defp dispatch_if_ready(state) do
    Logger.debug(
      "dispatch_if_ready called - demand: #{state.demand}, status: #{state.status}, queue size: #{length(state.manual_queue)}"
    )

    if state.status == :running and state.demand > 0 do
      Logger.debug("Conditions met, dispatching videos")
      dispatch_videos(state)
    else
      Logger.debug("Conditions not met for dispatch")
      {:noreply, [], state}
    end
  end

  defp broadcast_queue_state(manual_queue) do
    queue_items =
      Enum.map(manual_queue, fn video_info ->
        %{path: video_info.path, service_id: video_info.service_id}
      end)

    # Update the QueueManager with current queue state
    QueueManager.broadcast_queue_update(queue_items)

    # Also broadcast to analyzer topic for backward compatibility
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "analyzer",
      {:analyzer, :queue_updated, queue_items}
    )
  end

  defp dispatch_videos(state) do
    # First, dispatch any manually queued videos (e.g., force_reanalyze)
    {manual_videos, remaining_manual} = Enum.split(state.manual_queue, state.demand)

    dispatched_count = length(manual_videos)
    remaining_demand = state.demand - dispatched_count

    Logger.info("Dispatching videos - manual: #{length(manual_videos)}, remaining_demand: #{remaining_demand}")
    if length(manual_videos) > 0 do
      Logger.info("Manual videos being dispatched: #{inspect(Enum.map(manual_videos, & &1.path))}")
    end

    # If we still have demand after manual videos, get videos from the database
    database_videos =
      if remaining_demand > 0 do
        videos = Media.get_videos_needing_analysis(remaining_demand)
        Logger.info("Database videos fetched: #{length(videos)} videos")
        if length(videos) > 0 do
          Logger.info("Database video paths: #{inspect(Enum.map(videos, & &1.path))}")
        end
        videos
      else
        []
      end

    all_videos = manual_videos ++ database_videos

    case all_videos do
      [] ->
        # No videos available, keep the demand for later
        Logger.debug("No videos available for dispatch, keeping demand: #{state.demand}")
        {:noreply, [], state}

      videos ->
        Logger.info("Broadway producer dispatching #{length(videos)} videos for analysis")
        Logger.info("All videos being dispatched: #{inspect(Enum.map(videos, & &1.path))}")
        new_demand = state.demand - length(videos)
        new_state = State.update(state, demand: new_demand, manual_queue: remaining_manual)

        # Broadcast queue state change if manual queue changed
        if length(remaining_manual) != length(state.manual_queue) do
          broadcast_queue_state(remaining_manual)
        end

        {:noreply, videos, new_state}
    end
  end

  @doc """
  Debug function to check Broadway pipeline and producer status
  """
  def debug_status do
    broadway_name = Reencodarr.Analyzer.Broadway

    case Process.whereis(broadway_name) do
      nil ->
        IO.puts("❌ Broadway pipeline not found")
        {:error, :broadway_not_found}

      broadway_pid ->
        IO.puts("✅ Broadway pipeline found: #{inspect(broadway_pid)}")
        debug_producer_supervisor(broadway_name)
    end
  end

  defp debug_producer_supervisor(broadway_name) do
    producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

    case Process.whereis(producer_supervisor_name) do
      nil ->
        IO.puts("❌ Producer supervisor not found")
        {:error, :producer_supervisor_not_found}

      producer_supervisor_pid ->
        IO.puts("✅ Producer supervisor found: #{inspect(producer_supervisor_pid)}")
        debug_producer_children(producer_supervisor_pid)
    end
  end

  defp debug_producer_children(producer_supervisor_pid) do
    children = Supervisor.which_children(producer_supervisor_pid)
    IO.puts("Producer supervisor children: #{inspect(children)}")

    case find_actual_producer(children) do
      nil ->
        IO.puts("❌ Producer process not found in supervision tree")
        {:error, :producer_process_not_found}

      producer_pid ->
        IO.puts("✅ Producer process found: #{inspect(producer_pid)}")
        get_producer_state(producer_pid)
    end
  end

  # Helper to get and display producer state
  defp get_producer_state(producer_pid) do
    state = GenStage.call(producer_pid, :get_state, 1000)

    IO.puts(
      "State: demand=#{state.demand}, status=#{state.status}, queue_size=#{length(state.manual_queue)}"
    )

    if not Enum.empty?(state.manual_queue) do
      IO.puts("Manual queue contents:")
      Enum.each(state.manual_queue, fn video -> IO.puts("  - #{video.path}") end)
    end

    # Get up to 5 videos from queue or database for batching
    case get_next_videos(state, min(state.demand, 5)) do
      {[], new_state} ->
        Logger.debug("No videos available, resetting processing flag")
        # No videos available, reset processing flag
        {:noreply, [], %{new_state | processing: false}}

      {videos, new_state} ->
        video_count = length(videos)
        Logger.debug("Dispatching #{video_count} videos for analysis")
        # Decrement demand and mark as processing
        final_state =
          State.update(new_state, demand: state.demand - video_count, status: :processing)

        Logger.debug("Final state: status: #{final_state.status}, demand: #{final_state.demand}")

        {:noreply, videos, final_state}
    end
  end

  defp get_next_videos(state, max_count) do
    # First, get videos from the manual queue
    {queue_videos, remaining_queue} = take_from_queue(state.queue, max_count)
    new_state = %{state | queue: remaining_queue}

    remaining_needed = max_count - length(queue_videos)

    if remaining_needed > 0 do
      # Get additional videos from database
      db_videos = Media.get_videos_needing_analysis(remaining_needed)
      all_videos = queue_videos ++ db_videos
      {all_videos, new_state}
    else
      {queue_videos, new_state}
    end
  end

  defp take_from_queue(queue, max_count) do
    take_from_queue(queue, max_count, [])
  end

  defp take_from_queue(queue, 0, acc) do
    {Enum.reverse(acc), queue}
  end

  defp take_from_queue(queue, count, acc) when count > 0 do
    case :queue.out(queue) do
      {{:value, video}, remaining_queue} ->
        take_from_queue(remaining_queue, count - 1, [video | acc])

      {:empty, _queue} ->
        {Enum.reverse(acc), queue}
    end
  end
end
