defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Broadway producer for CRF search operations.

  This producer dispatches videos for CRF search only when the CRF search
  GenServer is available, preventing duplicate work and resource waste.
  """

  use GenStage
  require Logger
  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.PipelineStateMachine

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API for external control
  def pause, do: send_to_producer(:pause)
  def resume, do: send_to_producer(:resume)
  def dispatch_available, do: send_to_producer(:dispatch_available)
  def add_video(video), do: send_to_producer({:add_video, video})

  # Alias for API compatibility
  def start, do: resume()

  # Simplified - no cross-producer communication needed
  # If the process exists, it's running
  def running?, do: true

  # Check if actively processing by seeing if CRF searcher is busy
  def actively_running? do
    case CrfSearch.available?() do
      # Available means not actively running
      true -> false
      # Not available means actively processing
      false -> true
    end
  end

  @impl GenStage
  def init(_opts) do
    # Subscribe to video state transitions for videos that finished analysis
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")

    # Initialize pipeline state machine
    pipeline = PipelineStateMachine.new(:crf_searcher)

    {:producer,
     %{
       demand: 0,
       pipeline: pipeline
     }}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    current_status = PipelineStateMachine.get_state(state.pipeline)

    # Only accumulate demand if not currently processing
    # CRF search is single-concurrency, so we shouldn't accept more demand while busy
    # But we DO accept demand when paused (to allow resuming)
    if current_status == :processing do
      Logger.debug("[CRF Searcher Producer] Already processing, ignoring demand: #{demand}")
      {:noreply, [], state}
    else
      new_state = %{state | demand: state.demand + demand}
      dispatch_if_ready(new_state)
    end
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    # Button should reflect user intent - not running if paused or pausing
    running = PipelineStateMachine.running?(state.pipeline)
    {:reply, running, [], state}
  end

  @impl GenStage
  def handle_call(:actively_running?, _from, state) do
    # Check if actively processing (for telemetry/progress updates)
    actively_running = PipelineStateMachine.actively_working?(state.pipeline)
    {:reply, actively_running, [], state}
  end

  @impl GenStage
  def handle_cast({:status_request, requester_pid}, state) do
    current_state = PipelineStateMachine.get_state(state.pipeline)
    send(requester_pid, {:status_response, :crf_searcher, current_state})
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:broadcast_status, state) do
    # Broadcast actual current status to dashboard
    current_state = PipelineStateMachine.get_state(state.pipeline)

    # Map pipeline state to dashboard status
    status =
      case current_state do
        :processing -> :processing
        :paused -> :paused
        :running -> :running
        _ -> :stopped
      end

    # Broadcast as service_status event with the actual state
    Events.broadcast_event(:service_status, %{service: :crf_searcher, status: status})

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    new_state = Map.update!(state, :pipeline, &PipelineStateMachine.handle_pause_request/1)
    {:noreply, [], new_state}
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    dispatch_if_ready(Map.update!(state, :pipeline, &PipelineStateMachine.resume/1))
  end

  @impl GenStage
  def handle_cast({:add_video, video}, state) do
    Logger.info("Adding video to CRF searcher: #{video.path}")
    # No manual queue management - just trigger dispatch to check database
    # The video should already be in the database with :analyzed state
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    case PipelineStateMachine.get_state(state.pipeline) do
      :pausing ->
        {:noreply, [],
         Map.update!(state, :pipeline, &PipelineStateMachine.transition_to(&1, :paused))}

      _ ->
        dispatch_if_ready(Map.update!(state, :pipeline, &PipelineStateMachine.work_available/1))
    end
  end

  @impl GenStage
  def handle_info({:video_state_changed, video, :analyzed}, state) do
    # Video finished analysis - if CRF searcher is running, force dispatch even without demand
    Logger.debug("[CRF Searcher Producer] Received analyzed video: #{video.path}")

    current_state = PipelineStateMachine.get_state(state.pipeline)

    Logger.debug(
      "[CRF Searcher Producer] State: #{inspect(%{status: current_state, demand: state.demand})}"
    )

    force_dispatch_if_running(state)
  end

  @impl GenStage
  def handle_info({:video_state_changed, _video, _other_state}, state) do
    # Ignore other state transitions - CRF searcher only cares about :analyzed
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:crf_search_completed, _data}, state) do
    # CRF search completed - transition state appropriately
    current_state = PipelineStateMachine.get_state(state.pipeline)

    case current_state do
      :processing ->
        # Work completed while running - check for more work
        new_pipeline =
          PipelineStateMachine.work_completed(state.pipeline, crf_search_available?())

        updated_state = %{state | pipeline: new_pipeline}
        dispatch_if_ready(updated_state)
        {:noreply, [], updated_state}

      :pausing ->
        # Work completed while pausing - transition to paused and stop
        new_pipeline = PipelineStateMachine.work_completed(state.pipeline, false)
        updated_state = %{state | pipeline: new_pipeline}
        {:noreply, [], updated_state}

      _ ->
        # Already paused or other state - just acknowledge completion
        {:noreply, [], state}
    end
  end

  @impl GenStage
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # Private functions

  defp send_to_producer(message) do
    # Broadway manages producer names internally, so we need to get the actual name
    case Broadway.producer_names(Reencodarr.CrfSearcher.Broadway) do
      [producer_name | _] -> GenStage.cast(producer_name, message)
      [] -> {:error, :not_found}
    end
  end

  defp dispatch_if_ready(state) do
    if should_dispatch?(state) and state.demand > 0 do
      dispatch_videos(state)
    else
      handle_no_dispatch_crf_searcher(state)
    end
  end

  defp handle_no_dispatch_crf_searcher(state) do
    current_status = PipelineStateMachine.get_state(state.pipeline)

    if PipelineStateMachine.available_for_work?(current_status) do
      case Media.get_videos_for_crf_search(1) do
        [] ->
          # No videos to process - transition to idle
          new_pipeline = PipelineStateMachine.transition_to(state.pipeline, :idle)
          new_state = %{state | pipeline: new_pipeline}
          {:noreply, [], new_state}

        [_video | _] ->
          # Videos available but no demand or CRF service unavailable
          {:noreply, [], state}
      end
    else
      {:noreply, [], state}
    end
  end

  defp should_dispatch?(state) do
    PipelineStateMachine.running?(state.pipeline) and crf_search_available?()
  end

  defp crf_search_available? do
    # Check if the CRF searcher is available (not busy with another video)
    CrfSearch.available?()
  end

  defp dispatch_videos(state) do
    if state.demand > 0 and should_dispatch?(state) do
      # Get videos directly from database
      case Media.get_videos_for_crf_search(1) do
        [] ->
          {:noreply, [], state}

        [video | _] ->
          Logger.info(
            "🚀 CRF Producer: Dispatching video #{video.id} (#{video.title}) for CRF search"
          )

          # Mark as processing and decrement demand
          new_pipeline = PipelineStateMachine.start_processing(state.pipeline)
          updated_state = %{state | demand: state.demand - 1, pipeline: new_pipeline}

          {:noreply, [video], updated_state}
      end
    else
      {:noreply, [], state}
    end
  end

  # Helper function to force dispatch when CRF searcher is running
  defp force_dispatch_if_running(state) do
    current_state = PipelineStateMachine.get_state(state.pipeline)

    cond do
      not PipelineStateMachine.available_for_work?(current_state) ->
        Logger.debug(
          "[CRF Searcher Producer] Force dispatch - status: #{current_state}, not available for work, skipping dispatch"
        )

        {:noreply, [], state}

      not crf_search_available?() ->
        Logger.debug("[CRF Searcher Producer] GenServer not available, skipping dispatch")
        {:noreply, [], state}

      Media.get_videos_for_crf_search(1) == [] ->
        {:noreply, [], state}

      true ->
        Logger.debug(
          "[CRF Searcher Producer] Force dispatching video to wake up idle Broadway pipeline"
        )

        dispatch_if_ready(state)
    end
  end
end
