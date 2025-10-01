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

  def get_producer_state do
    # Get the current producer state for debugging
    case Broadway.producer_names(Reencodarr.CrfSearcher.Broadway) do
      [producer_name | _] -> GenServer.call(producer_name, :get_debug_state, 5000)
      [] -> {:error, :not_running}
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
    new_state = %{state | demand: state.demand + demand}
    dispatch_if_ready(new_state)
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
  def handle_call(:get_debug_state, _from, state) do
    debug_info = %{
      demand: state.demand,
      pipeline_state: PipelineStateMachine.get_state(state.pipeline),
      pipeline_running: PipelineStateMachine.running?(state.pipeline),
      crf_search_available: crf_search_available?(),
      should_dispatch: should_dispatch?(state),
      queue_count: length(Media.get_videos_for_crf_search(10))
    }

    {:reply, debug_info, [], state}
  end

  @impl GenStage
  def handle_cast({:status_request, requester_pid}, state) do
    current_state = PipelineStateMachine.get_state(state.pipeline)
    send(requester_pid, {:status_response, :crf_searcher, current_state})
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
  def handle_info({:crf_search_completed, _video_id, _result}, state) do
    # CRF search completed - transition state appropriately
    current_state = PipelineStateMachine.get_state(state.pipeline)

    updated_state =
      case current_state do
        :processing ->
          new_pipeline =
            PipelineStateMachine.work_completed(state.pipeline, crf_search_available?())

          %{state | pipeline: new_pipeline}

        :pausing ->
          new_pipeline = PipelineStateMachine.work_completed(state.pipeline, false)
          %{state | pipeline: new_pipeline}

        _ ->
          state
      end

    # Check for more work
    dispatch_if_ready(updated_state)
    {:noreply, [], updated_state}
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

    case {PipelineStateMachine.available_for_work?(current_state), crf_search_available?()} do
      {false, _} ->
        Logger.debug(
          "[CRF Searcher Producer] Force dispatch - status: #{current_state}, not available for work, skipping dispatch"
        )

        {:noreply, [], state}

      {true, false} ->
        Logger.debug("[CRF Searcher Producer] Force dispatch - status: #{current_state}")
        Logger.debug("[CRF Searcher Producer] GenServer not available, skipping dispatch")
        {:noreply, [], state}

      {true, true} ->
        Logger.debug("[CRF Searcher Producer] Force dispatch - status: #{current_state}")
        Logger.debug("[CRF Searcher Producer] GenServer available, getting videos...")

        case Media.get_videos_for_crf_search(1) do
          [] ->
            {:noreply, [], state}

          videos ->
            Logger.debug(
              "[CRF Searcher Producer] Force dispatching video to wake up idle Broadway pipeline"
            )

            {:noreply, videos, state}
        end
    end
  end
end
