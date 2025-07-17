defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway producer for analyzer operations.

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
      :paused,
      :manual_queue
    ]

    def update(state, updates) do
      struct(state, updates)
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

  @impl GenStage
  def init(_opts) do
    # Subscribe to media events for new videos
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to analyzer events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer_events")

    {:producer,
     %{
       demand: 0,
       paused: true,
       queue: :queue.new(),
       # Track if we're currently processing videos
       processing: false
     }}
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    {:reply, not state.paused, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    Logger.info("Analyzer paused")
    Telemetry.emit_analyzer_paused()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
    :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})
    {:noreply, [], State.update(state, paused: true)}
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("Analyzer resumed")
    Telemetry.emit_analyzer_started()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :started})
    :telemetry.execute([:reencodarr, :analyzer, :started], %{}, %{})
    new_state = State.update(state, paused: false)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast({:add_video, video_info}, state) do
    Logger.debug("Adding video to Broadway queue: #{video_info.path}")

    Logger.debug(
      "Current state - demand: #{state.demand}, paused: #{state.paused}, queue size: #{length(state.manual_queue)}"
    )

    new_manual_queue = [video_info | state.manual_queue]
    new_state = State.update(state, manual_queue: new_manual_queue)
    Logger.debug("After adding - queue size: #{length(new_state.manual_queue)}")

    # Broadcast queue state change
    broadcast_queue_state(new_state.manual_queue)

    dispatch_if_ready(new_state)
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
    # Batch analysis completed, mark as not processing and try to dispatch next
    Logger.debug("Producer: Received batch analysis completion notification")
    new_state = %{state | processing: false}
    dispatch_if_ready(new_state)
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
      "dispatch_if_ready called - demand: #{state.demand}, paused: #{state.paused}, queue size: #{length(state.manual_queue)}"
    )

    if not state.paused and state.demand > 0 do
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

    # If we still have demand after manual videos, get videos from the database
    database_videos =
      if remaining_demand > 0 do
        Media.get_videos_needing_analysis(remaining_demand)
      else
        []
      end

    all_videos = manual_videos ++ database_videos

    case all_videos do
      [] ->
        # No videos available, keep the demand for later
        {:noreply, [], state}

      videos ->
        Logger.debug("Broadway producer dispatching #{length(videos)} videos for analysis")
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

        # Check for producer supervisor
        producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

        case Process.whereis(producer_supervisor_name) do
          nil ->
            IO.puts("❌ Producer supervisor not found")
            {:error, :producer_supervisor_not_found}

          producer_supervisor_pid ->
            IO.puts("✅ Producer supervisor found: #{inspect(producer_supervisor_pid)}")

            # Get children of producer supervisor to find our producer
            children = Supervisor.which_children(producer_supervisor_pid)
            IO.puts("Producer supervisor children: #{inspect(children)}")

            # Find the actual producer process
            case find_actual_producer(children) do
              nil ->
                IO.puts("❌ Producer process not found in supervision tree")
                {:error, :producer_process_not_found}

              producer_pid ->
                IO.puts("✅ Producer process found: #{inspect(producer_pid)}")
                get_producer_state(producer_pid)
            end
        end
    end
  end

  # Helper to get and display producer state
  defp get_producer_state(producer_pid) do
    state = GenStage.call(producer_pid, :get_state, 1000)

    IO.puts(
      "State: demand=#{state.demand}, paused=#{state.paused}, queue_size=#{length(state.manual_queue)}"
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
        # Decrement demand but keep processing: true
        final_state = %{new_state | demand: state.demand - video_count}

        Logger.debug(
          "Final state: processing: #{final_state.processing}, demand: #{final_state.demand}"
        )

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
