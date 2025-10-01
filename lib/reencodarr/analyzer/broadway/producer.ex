defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway producer for analyzer operations.

  This producer dispatches videos for analysis in batches of up to 5,
  managing demand and batch processing for optimal mediainfo usage.
  """

  use GenStage
  require Logger
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.PipelineStateMachine

  @broadway_name Reencodarr.Analyzer.Broadway

  defmodule State do
    @moduledoc false
    defstruct [
      :demand,
      :pipeline,
      :paused,
      :processing,
      :pending_videos
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
        GenStage.call(producer_pid, :running?, 1000)
    end
  end

  def actively_running? do
    case find_producer_process() do
      nil ->
        false

      producer_pid ->
        GenStage.call(producer_pid, :actively_running?, 1000)
    end
  end

  @impl GenStage
  def init(_opts) do
    # Subscribe to media events for new videos
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to video state transitions for new videos needing analysis
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")
    # Subscribe to analyzer events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer_events")

    # Send a delayed message to trigger initial dispatch
    Process.send_after(self(), :initial_dispatch, 1000)

    {:producer,
     %State{
       demand: 0,
       pipeline: PipelineStateMachine.new(:analyzer)
     }}
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    # Button should reflect user intent - use centralized state machine
    running = PipelineStateMachine.running?(state.pipeline)
    {:reply, running, [], state}
  end

  @impl GenStage
  def handle_call(:actively_running?, _from, state) do
    # For telemetry/progress - actively running if processing or pausing
    actively_running = PipelineStateMachine.actively_working?(state.pipeline)
    {:reply, actively_running, [], state}
  end

  @impl GenStage
  def handle_call(:get_state, _from, state) do
    {:reply, state, [], state}
  end

  @impl GenStage
  def handle_cast({:status_request, requester_pid}, state) do
    current_state = PipelineStateMachine.get_state(state.pipeline)
    send(requester_pid, {:status_response, :analyzer, current_state})
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:broadcast_status, state) do
    p = state.pipeline
    Events.pipeline_state_changed(p.service, p.current_state, p.current_state)
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    {:noreply, [], Map.update!(state, :pipeline, &PipelineStateMachine.pause/1)}
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    dispatch_if_ready(Map.update!(state, :pipeline, &PipelineStateMachine.resume/1))
  end

  @impl GenStage
  def handle_cast({:add_video, video_info}, state) do
    Logger.info("Adding video to Broadway queue: #{video_info.path}")
    Logger.debug("video info details", video_info: video_info)

    current_state = PipelineStateMachine.get_state(state.pipeline)

    Logger.debug("Current state - demand: #{state.demand}, status: #{current_state}")

    # No manual queue management - just trigger dispatch to check database
    # The video should already be in the database with :needs_analysis state
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    # Handle work availability and determine next steps
    case PipelineStateMachine.get_state(state.pipeline) do
      :pausing ->
        {:noreply, [],
         Map.update!(state, :pipeline, &PipelineStateMachine.transition_to(&1, :paused))}

      _ ->
        dispatch_if_ready(Map.update!(state, :pipeline, &PipelineStateMachine.work_available/1))
    end
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    Logger.debug("Broadway producer received demand for #{demand} items")
    new_state = State.update(state, demand: state.demand + demand)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info({:video_upserted, _video}, state) do
    # New video was upserted - force dispatch to wake up idle Broadway
    force_dispatch_if_running(state)
  end

  @impl GenStage
  def handle_info({:video_state_changed, video, :needs_analysis}, state) do
    # Video needs analysis - if analyzer is running, force dispatch even without demand
    Logger.debug("[Analyzer Producer] Received video needing analysis: #{video.path}")
    force_dispatch_if_running(state)
  end

  @impl GenStage
  def handle_info({:analysis_completed, _path, _result}, state) do
    # Individual analysis completed - this is handled by batch completion now
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:batch_analysis_completed, _batch_size}, state) do
    # Batch analysis completed - use state machine to determine next state
    Logger.debug("Producer: Received batch analysis completion notification")

    has_more_work = Media.count_videos_needing_analysis() > 0

    new_state =
      Map.update!(state, :pipeline, &PipelineStateMachine.work_completed(&1, has_more_work))

    if has_more_work and PipelineStateMachine.available_for_work?(new_state.pipeline) do
      dispatch_if_ready(new_state)
    else
      {:noreply, [], new_state}
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
    Enum.find_value(children, &find_running_producer/1)
  end

  defp find_running_producer({_id, pid, _type, _modules}) when is_pid(pid) do
    if Process.alive?(pid) do
      GenStage.call(pid, :running?, 1000)
      pid
    else
      nil
    end
  end

  defp find_running_producer(_), do: nil

  defp dispatch_if_ready(state) do
    current_state = PipelineStateMachine.get_state(state.pipeline)

    Logger.debug("dispatch_if_ready called - demand: #{state.demand}, status: #{current_state}")

    case can_dispatch?(state) do
      {:auto_start, state} -> handle_auto_start(state)
      {:resume_idle, state} -> handle_resume_from_idle(state)
      {:dispatch, state} -> dispatch_videos(state)
      {:no_dispatch, state} -> handle_no_dispatch_conditions(state)
    end
  end

  defp can_dispatch?(state) do
    cond do
      ready_for_auto_start?(state) -> {:auto_start, state}
      ready_for_resume_from_idle?(state) -> {:resume_idle, state}
      ready_for_dispatch?(state) -> {:dispatch, state}
      true -> {:no_dispatch, state}
    end
  end

  defp ready_for_auto_start?(state) do
    PipelineStateMachine.get_state(state.pipeline) == :paused and state.demand > 0 and
      Media.count_videos_needing_analysis() > 0
  end

  defp ready_for_resume_from_idle?(state) do
    PipelineStateMachine.get_state(state.pipeline) == :idle and state.demand > 0 and
      Media.count_videos_needing_analysis() > 0
  end

  defp ready_for_dispatch?(state) do
    PipelineStateMachine.get_state(state.pipeline) == :running and state.demand > 0
  end

  defp handle_auto_start(state) do
    Logger.info("Auto-starting analyzer - videos available for processing")

    # Send to Dashboard using Events system
    Events.broadcast_event(:analyzer_started, %{})
    # Start with minimal progress to indicate activity
    Events.broadcast_event(:analyzer_progress, %{
      count: 0,
      total: 1,
      percent: 0
    })

    # Only transition if not already running
    new_pipeline =
      if PipelineStateMachine.get_state(state.pipeline) != :running do
        PipelineStateMachine.transition_to(state.pipeline, :running)
      else
        state.pipeline
      end

    new_state = %{state | pipeline: new_pipeline}
    dispatch_videos(new_state)
  end

  defp handle_resume_from_idle(state) do
    Logger.info("Analyzer resuming from idle - videos available for processing")

    # Send to Dashboard V2
    alias Reencodarr.Dashboard.Events
    Events.broadcast_event(:analyzer_started, %{})
    # Start with minimal progress to indicate activity
    Events.broadcast_event(:analyzer_progress, %{
      count: 0,
      total: 1,
      percent: 0
    })

    # Only transition if not already running
    new_pipeline =
      if PipelineStateMachine.get_state(state.pipeline) != :running do
        PipelineStateMachine.transition_to(state.pipeline, :running)
      else
        state.pipeline
      end

    new_state = %{state | pipeline: new_pipeline}
    dispatch_videos(new_state)
  end

  defp handle_no_dispatch_conditions(state) do
    Logger.debug("Conditions not met for dispatch - demand: #{state.demand}")

    # If analyzer is running but has no work to do, set to idle instead of paused
    if PipelineStateMachine.get_state(state.pipeline) == :running and state.demand == 0 and
         Media.count_videos_needing_analysis() == 0 do
      handle_idle_transition(state)
    else
      {:noreply, [], state}
    end
  end

  defp handle_idle_transition(state) do
    # Check if there are any videos needing analysis in the database
    database_queue_count = Reencodarr.Media.count_videos_needing_analysis()

    if database_queue_count == 0 do
      Logger.debug("Analyzer has no work - setting to idle")
      # Set to idle - ready to work but no current tasks
      new_state = %{state | pipeline: PipelineStateMachine.transition_to(state.pipeline, :idle)}
      {:noreply, [], new_state}
    else
      Logger.debug(
        "Analyzer has #{database_queue_count} videos to analyze but no demand - staying running"
      )

      {:noreply, [], state}
    end
  end

  defp dispatch_videos(state) do
    # Get videos from the database up to demand
    videos = Media.get_videos_needing_analysis(state.demand)

    Logger.debug("Dispatching videos - demand: #{state.demand}, found: #{length(videos)}")

    if length(videos) > 0 do
      Logger.debug("Videos being dispatched: #{inspect(Enum.map(videos, & &1.path))}")

      debug_video_states(videos)
    end

    case videos do
      [] ->
        # No videos available - go to idle if currently running
        if PipelineStateMachine.get_state(state.pipeline) == :running do
          Logger.info("Analyzer going idle - no videos to process")

          new_state = %{
            state
            | pipeline: PipelineStateMachine.transition_to(state.pipeline, :idle)
          }

          {:noreply, [], new_state}
        else
          Logger.debug("No videos available for dispatch, keeping demand: #{state.demand}")
          {:noreply, [], state}
        end

      videos ->
        Logger.debug("Broadway producer dispatching #{length(videos)} videos for analysis")
        Logger.debug("All videos being dispatched: #{inspect(Enum.map(videos, & &1.path))}")
        new_demand = state.demand - length(videos)
        new_state = State.update(state, demand: new_demand)

        {:noreply, videos, new_state}
    end
  end

  # Debug helper function to check video states
  defp debug_video_states(videos) do
    Enum.each(videos, fn video_info ->
      case Media.get_video_by_path(video_info.path) do
        {:error, :not_found} ->
          Logger.debug("video not found in database", path: video_info.path)

        {:ok, video} ->
          Logger.debug("video state check", path: video_info.path, state: video.state)
      end
    end)
  end

  # Helper function to force dispatch when analyzer is running
  defp force_dispatch_if_running(%State{pipeline: pipeline, demand: 0} = state) do
    if PipelineStateMachine.get_state(pipeline) == :running do
      videos = Media.get_videos_needing_analysis(1)

      if length(videos) > 0 do
        Logger.debug(
          "[Analyzer Producer] Force dispatching video to wake up idle Broadway pipeline"
        )

        # Temporarily add demand to force dispatch, then call dispatch_if_ready
        temp_state = State.update(state, demand: 1)
        dispatch_if_ready(temp_state)
      else
        {:noreply, [], state}
      end
    else
      {:noreply, [], state}
    end
  end

  defp force_dispatch_if_running(state) do
    # Already has demand or not running, use normal dispatch
    dispatch_if_ready(state)
  end
end
