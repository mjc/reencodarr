defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway produc     {:producer,
     %State{
       demand: 0,
       status: :paused,
       queue: :queue.new()
     }}analyzer operations.

  This producer dispatches videos for analysis in batches of up to 5,
  managing demand and batch processing for optimal mediainfo usage.
  """

  use GenStage
  require Logger
  alias Reencodarr.{Media, Telemetry}

  @broadway_name Reencodarr.Analyzer.Broadway

  defmodule State do
    @moduledoc false
    defstruct [
      :demand,
      :status,
      :queue
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
       queue: :queue.new()
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
  def handle_cast(:dispatch_available, state) do
    # Trigger dispatch to check for videos that need analysis
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    new_state = State.update(state, demand: state.demand + demand)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info({:video_upserted, _video}, state) do
    # Video was updated - refresh queue telemetry and check for dispatch
    emit_initial_telemetry(state)
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info({:analysis_completed, _path, _result}, state) do
    # Analysis completed - reset status to running if we were processing
    new_status =
      case state.status do
        :processing -> :running
        :pausing -> :paused
        other -> other
      end

    new_state = State.update(state, status: new_status)

    # Refresh queue telemetry and check for more work
    emit_initial_telemetry(new_state)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info(:initial_dispatch, state) do
    # Trigger initial dispatch after startup to check for videos needing analysis

    # Emit initial telemetry regardless of producer status so dashboard shows queue on startup
    emit_initial_telemetry(state)

    # Schedule periodic telemetry updates
    Process.send_after(self(), :periodic_telemetry, 5000)

    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info(:periodic_telemetry, state) do
    # Emit periodic telemetry to keep dashboard updated
    emit_initial_telemetry(state)

    # Schedule next update
    Process.send_after(self(), :periodic_telemetry, 5000)

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # Private functions

  defp send_to_producer(message) do
    case find_producer_process() do
      nil ->
        Logger.error("Producer: Producer process not found!")
        {:error, :producer_not_found}

      producer_pid ->
        GenStage.cast(producer_pid, message)
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
    if state.demand > 0 and state.status == :running do
      dispatch_videos(state)
    else
      {:noreply, [], state}
    end
  end

  defp dispatch_videos(state) do
    if state.demand > 0 do
      # Get one video from database that needs analysis
      case Media.get_videos_needing_analysis(1) do
        [video | _] ->
          new_demand = state.demand - 1
          new_state = State.update(state, demand: new_demand)

          # Get remaining videos for queue state update (sample for display)
          remaining_videos = Media.get_videos_needing_analysis(10)
          # Get total count for accurate queue size
          total_count = get_total_analysis_queue_count()

          # Emit telemetry event for queue state change
          :telemetry.execute(
            [:reencodarr, :analyzer, :queue_changed],
            %{dispatched_count: 1, remaining_demand: new_demand, queue_size: total_count},
            %{
              next_videos: remaining_videos,
              database_queue_available: total_count > 0
            }
          )

          {:noreply, [video], new_state}

        [] ->
          # No videos available - emit empty queue telemetry
          :telemetry.execute(
            [:reencodarr, :analyzer, :queue_changed],
            %{dispatched_count: 0, remaining_demand: state.demand, queue_size: 0},
            %{
              next_videos: [],
              database_queue_available: false
            }
          )

          {:noreply, [], state}
      end
    else
      {:noreply, [], state}
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

    IO.puts("State: demand=#{state.demand}, status=#{state.status}")

    # Get up to 5 videos from queue or database for batching
    case get_next_videos(state, min(state.demand, 5)) do
      {[], new_state} ->
        # No videos available, reset processing flag
        {:noreply, [], %{new_state | processing: false}}

      {videos, new_state} ->
        video_count = length(videos)
        # Decrement demand and mark as processing
        final_state =
          State.update(new_state, demand: state.demand - video_count, status: :processing)

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

  # Emit initial telemetry on startup to populate dashboard queues
  defp emit_initial_telemetry(state) do
    next_videos = get_next_videos_for_telemetry(state)
    total_count = get_total_analysis_queue_count()

    measurements = %{
      queue_size: total_count
    }

    metadata = %{
      producer_type: :analyzer,
      next_videos: next_videos
    }

    :telemetry.execute([:reencodarr, :analyzer, :queue_changed], measurements, metadata)
  end

  # Get next videos for telemetry (similar to dispatch_videos logic but without state changes)
  defp get_next_videos_for_telemetry(_state) do
    # Get videos from database that need analysis
    db_videos = Media.get_videos_needing_analysis(10)
    db_videos
  end

  defp get_total_analysis_queue_count do
    # Efficiently count total videos needing analysis
    Media.count_videos_needing_analysis()
  end
end
