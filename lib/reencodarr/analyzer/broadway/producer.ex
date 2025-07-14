defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway producer for video analysis operations.

  This producer replaces the GenStage producer and provides videos for analysis
  to the Broadway pipeline with better rate limiting and back-pressure handling.
  """

  use GenStage
  require Logger
  alias Reencodarr.Media

  defmodule State do
    @moduledoc false
    defstruct [
      :demand,
      :paused,
      :manual_queue,
      :processing
    ]
  end

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a video to the manual queue for processing.
  """
  def add_video(video_info) do
    broadway_name = Reencodarr.Analyzer.Broadway
    producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

    case Process.whereis(producer_supervisor_name) do
      nil ->
        Logger.error("Producer supervisor not found, cannot add video")
        {:error, :producer_supervisor_not_found}

      producer_supervisor_pid ->
        children = Supervisor.which_children(producer_supervisor_pid)

        case find_producer_process(children) do
          nil ->
            Logger.error("Producer process not found, cannot add video")
            {:error, :producer_process_not_found}

          producer_pid ->
            GenStage.cast(producer_pid, {:add_video, video_info})
        end
    end
  end

  @doc """
  Pause the producer.
  """
  def pause do
    broadway_name = Reencodarr.Analyzer.Broadway
    producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

    case Process.whereis(producer_supervisor_name) do
      nil ->
        {:error, :producer_supervisor_not_found}

      producer_supervisor_pid ->
        children = Supervisor.which_children(producer_supervisor_pid)

        case find_producer_process(children) do
          nil -> {:error, :producer_process_not_found}
          producer_pid -> GenStage.cast(producer_pid, :pause)
        end
    end
  end

  @doc """
  Resume the producer.
  """
  def resume do
    broadway_name = Reencodarr.Analyzer.Broadway
    producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

    case Process.whereis(producer_supervisor_name) do
      nil ->
        {:error, :producer_supervisor_not_found}

      producer_supervisor_pid ->
        children = Supervisor.which_children(producer_supervisor_pid)

        case find_producer_process(children) do
          nil -> {:error, :producer_process_not_found}
          producer_pid -> GenStage.cast(producer_pid, :resume)
        end
    end
  end

  @doc """
  Check if the producer is running.
  """
  def running? do
    broadway_name = Reencodarr.Analyzer.Broadway

    case Process.whereis(broadway_name) do
      nil ->
        false

      _broadway_pid ->
        producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

        case Process.whereis(producer_supervisor_name) do
          nil ->
            false

          producer_supervisor_pid ->
            children = Supervisor.which_children(producer_supervisor_pid)

            case find_producer_process(children) do
              nil -> false
              producer_pid -> GenStage.call(producer_pid, :running?, 1000)
            end
        end
    end
  rescue
    # If any call fails, the producer is not running properly
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl GenStage
  def init(_opts) do
    # Subscribe to media events that indicate new items are available
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to analyzer events to know when analysis completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer_events")

    # Start in paused state by default for safety
    state = %State{
      demand: 0,
      paused: true,
      manual_queue: [],
      processing: false
    }

    # Broadcast initial empty queue state
    broadcast_queue_state(state.manual_queue)

    {:producer, state}
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    {:reply, not state.paused, [], state}
  end

  @impl GenStage
  def handle_call(:get_state, _from, state) do
    # Provide the full state for debugging
    {:reply, state, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    Logger.info("Analyzer Broadway producer paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
    :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})
    {:noreply, [], %{state | paused: true}}
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("Analyzer Broadway producer resumed")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :started})
    :telemetry.execute([:reencodarr, :analyzer, :started], %{}, %{})
    new_state = %{state | paused: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast({:add_video, video_info}, state) do
    Logger.debug("Adding video to Broadway queue: #{video_info.path}")

    Logger.debug(
      "Current state - demand: #{state.demand}, paused: #{state.paused}, queue size: #{length(state.manual_queue)}"
    )

    new_manual_queue = [video_info | state.manual_queue]
    new_state = %{state | manual_queue: new_manual_queue}
    Logger.debug("After adding - queue size: #{length(new_state.manual_queue)}")

    # Broadcast queue state change
    broadcast_queue_state(new_state.manual_queue)

    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    Logger.debug("Broadway producer received demand for #{demand} items")
    new_state = %{state | demand: state.demand + demand}
    # Only dispatch if we're not already processing something
    if not state.processing do
      dispatch_if_ready(new_state)
    else
      # If we're already processing, just store the demand for later
      {:noreply, [], new_state}
    end
  end

  @impl GenStage
  def handle_info({:video_upserted, _video}, state) do
    # New video created, might have items ready for analysis
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info({:vmaf_upserted, _vmaf}, state) do
    # VMAF created - Analyzer doesn't need to react to this
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:analysis_completed, _video_id, _result}, state) do
    # Analysis completed (success or failure), mark as not processing and try to dispatch next
    Logger.debug("Producer: Received analysis completion notification")
    new_state = %{state | processing: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info(_msg, state) do
    # Ignore other PubSub messages
    {:noreply, [], state}
  end

  # Helper function to reduce duplication
  defp dispatch_if_ready(state) do
    Logger.debug(
      "dispatch_if_ready called - demand: #{state.demand}, paused: #{state.paused}, processing: #{state.processing}, queue size: #{length(state.manual_queue)}"
    )

    if should_dispatch?(state) and state.demand > 0 do
      Logger.debug("Conditions met, dispatching videos")
      dispatch_videos(state)
    else
      Logger.debug("Conditions not met for dispatch")
      {:noreply, [], state}
    end
  end

  # Helper to find the producer process from supervisor children
  defp find_producer_process(children) do
    Enum.find_value(children, fn {_id, pid, _type, _modules} ->
      if is_pid(pid) do
        # Try to call our custom method to identify this as our producer
        GenStage.call(pid, :get_state, 1000)
        pid
      end
    end)
  rescue
    _ -> nil
  catch
    _ -> nil
  end

  # Broadcast queue state changes to QueueManager
  defp broadcast_queue_state(manual_queue) do
    queue_items =
      Enum.map(manual_queue, fn video_info ->
        %{
          path: video_info.path,
          service_id: video_info.service_id,
          service_type: video_info.service_type,
          force_reanalyze: Map.get(video_info, :force_reanalyze, false)
        }
      end)

    Reencodarr.Analyzer.QueueManager.broadcast_queue_update(queue_items)
  end

  defp should_dispatch?(state) do
    result = not state.paused and not state.processing and analysis_available?()

    Logger.debug(
      "should_dispatch? paused: #{state.paused}, processing: #{state.processing}, analysis_available: #{analysis_available?()}, result: #{result}"
    )

    result
  end

  # Check if the analysis system is ready to process videos
  defp analysis_available? do
    # For now, we'll assume analysis is always available since it's done in Broadway
    # In the future, this could check system resources or other constraints
    true
  end

  defp dispatch_videos(state) do
    Logger.debug(
      "dispatch_videos called with processing: #{state.processing}, demand: #{state.demand}"
    )

    # Mark as processing immediately to prevent duplicate dispatches
    updated_state = %{state | processing: true}
    Logger.debug("Setting processing: true")

    # Get next video from queue or database (single item to match encoder pattern)
    case get_next_video(updated_state) do
      {nil, new_state} ->
        Logger.debug("No video available, resetting processing flag")
        # No video available, reset processing flag
        {:noreply, [], %{new_state | processing: false}}

      {video, new_state} ->
        Logger.debug("Dispatching video #{video.path} for analysis")
        # Decrement demand but keep processing: true
        final_state = %{new_state | demand: state.demand - 1}

        Logger.debug(
          "Final state: processing: #{final_state.processing}, demand: #{final_state.demand}"
        )

        {:noreply, [video], final_state}
    end
  end

  defp get_next_video(state) do
    case state.manual_queue do
      [video | remaining_queue] ->
        new_state = %{state | manual_queue: remaining_queue}
        # Broadcast queue state change
        broadcast_queue_state(remaining_queue)
        {video, new_state}

      [] ->
        case Media.get_next_for_analysis(1) do
          # Handle case where a single video is returned
          %{path: _} = video -> {video, state}
          # Handle case where a list is returned
          [video | _] -> {video, state}
          # Handle case where an empty list is returned
          [] -> {nil, state}
          # Handle case where nil is returned
          nil -> {nil, state}
        end
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
            case find_producer_process(children) do
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
      "State: demand=#{state.demand}, paused=#{state.paused}, processing=#{state.processing}, queue_size=#{length(state.manual_queue)}"
    )

    if not Enum.empty?(state.manual_queue) do
      IO.puts("Queued videos:")
      Enum.each(state.manual_queue, fn video -> IO.puts("  - #{video.path}") end)
    end

    {:ok, state}
  rescue
    e ->
      IO.puts("❌ Error getting state: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Debug function to test adding a video directly
  """
  def debug_add_video(path \\ "/test/path") do
    IO.puts("Testing add_video with path: #{path}")
    video_info = %{path: path, service_id: 1, service_type: "test", force_reanalyze: true}
    add_video(video_info)
  end
end
