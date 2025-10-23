defmodule Reencodarr.Encoder.Broadway.Producer do
  @moduledoc """
  Broadway producer for encoding operations.

  This producer dispatches VMAFs for encoding only when the encoding
  GenServer is available, preventing duplicate work and resource waste.
  """

  use GenStage
  require Logger
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.PipelineStateMachine

  @broadway_name Reencodarr.Encoder.Broadway

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API for external control
  def pause, do: send_to_producer(:pause)
  def resume, do: send_to_producer(:resume)
  def dispatch_available, do: send_to_producer(:dispatch_available)
  def add_vmaf(vmaf), do: send_to_producer({:add_vmaf, vmaf})

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

  # Check if actively processing (for telemetry/progress updates)
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
    # Subscribe to video state transitions for videos that finished CRF search
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")
    # Subscribe to dashboard events to know when encoding completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

    {:producer,
     %{
       demand: 0,
       pipeline: PipelineStateMachine.new(:encoder)
     }}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    Logger.debug(
      "Producer: handle_demand called - new demand: #{demand}, current demand: #{state.demand}, total: #{state.demand + demand}"
    )

    # Only accumulate demand if not currently processing
    # Encoder is single-concurrency, so we shouldn't accept more demand while busy
    current_status = PipelineStateMachine.get_state(state.pipeline)

    if current_status == :processing do
      # If we're already processing, ignore the demand
      Logger.debug("Producer: handle_demand - currently processing, ignoring demand")
      {:noreply, [], state}
    else
      new_state = %{state | demand: state.demand + demand}
      Logger.debug("Producer: handle_demand - not processing, calling dispatch_if_ready")
      dispatch_if_ready(new_state)
    end
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    # Button should reflect user intent - not running if paused or pausing
    current_status = PipelineStateMachine.get_state(state.pipeline)
    running = PipelineStateMachine.running?(current_status)
    {:reply, running, [], state}
  end

  @impl GenStage
  def handle_call(:actively_running?, _from, state) do
    # For telemetry/progress - actively running if processing or pausing
    # This allows progress to continue during pausing state
    current_status = PipelineStateMachine.get_state(state.pipeline)

    actively_running =
      PipelineStateMachine.actively_working?(current_status) or current_status == :pausing

    {:reply, actively_running, [], state}
  end

  @impl GenStage
  def handle_cast({:status_request, requester_pid}, state) do
    current_status = PipelineStateMachine.get_state(state.pipeline)
    send(requester_pid, {:status_response, :encoder, current_status})
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
    Events.broadcast_event(:service_status, %{service: :encoder, status: status})

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
  def handle_cast({:add_vmaf, vmaf}, state) do
    Logger.info("Adding VMAF to encoder: #{vmaf.id}")
    # No manual queue management - just trigger dispatch to check database
    # The VMAF should already be in the database with chosen=true state
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
  def handle_info({:video_state_changed, video, :crf_searched}, state) do
    # Video finished CRF search - if encoder is running, force dispatch even without demand
    Logger.debug("[Encoder Producer] Received CRF searched video: #{video.path}")
    force_dispatch_if_running(state)
  end

  @impl GenStage
  def handle_info({:video_state_changed, _video, _other_state}, state) do
    # Ignore other state transitions - encoder only cares about :crf_searched
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:vmaf_upserted, _vmaf}, state) do
    # VMAF was created/updated - check if it's chosen and ready for encoding
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info({:crf_search_vmaf_result, _data}, state) do
    # CRF search results don't affect encoder - ignore
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:encoding_completed, %{vmaf_id: vmaf_id, result: result} = event_data}, state) do
    # Encoding completed (success or failure), transition back to running
    Logger.info(
      "[Encoder Producer] *** RECEIVED ENCODING COMPLETION *** - VMAF: #{vmaf_id}, result: #{inspect(result)}, event: #{inspect(event_data)}"
    )

    current_status = PipelineStateMachine.get_state(state.pipeline)

    Logger.debug(
      "[Encoder Producer] Current state before transition - status: #{current_status}, demand: #{state.demand}"
    )

    case current_status do
      :processing ->
        # Work completed while running - check for more work
        updated_pipeline =
          PipelineStateMachine.work_completed(state.pipeline, Media.encoding_queue_count() > 0)

        new_state = %{state | pipeline: updated_pipeline}
        new_status = PipelineStateMachine.get_state(updated_pipeline)

        Logger.debug(
          "[Encoder Producer] State after transition - status: #{new_status}, demand: #{new_state.demand}"
        )

        dispatch_if_ready(new_state)

      :pausing ->
        # Work completed while pausing - transition to paused and stop
        updated_pipeline = PipelineStateMachine.work_completed(state.pipeline, false)
        new_state = %{state | pipeline: updated_pipeline}

        Logger.debug("[Encoder Producer] Pausing complete, now paused")
        {:noreply, [], new_state}

      _ ->
        # Already paused or other state - just acknowledge completion
        Logger.debug("[Encoder Producer] Encoding completed in state #{current_status}, ignoring")
        {:noreply, [], state}
    end
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
      if is_pid(pid) and Process.alive?(pid) do
        GenStage.call(pid, :running?, 1000)
        pid
      end
    end)
  end

  defp dispatch_if_ready(state) do
    current_status = PipelineStateMachine.get_state(state.pipeline)

    Logger.debug(
      "Producer: dispatch_if_ready called - status: #{current_status}, demand: #{state.demand}"
    )

    if should_dispatch?(state) and state.demand > 0 do
      Logger.debug("Producer: dispatch_if_ready - conditions met, dispatching VMAFs")
      dispatch_vmafs(state)
    else
      Logger.debug(
        "Producer: dispatch_if_ready - conditions NOT met, not dispatching (should_dispatch: #{should_dispatch?(state)}, demand: #{state.demand})"
      )

      handle_no_dispatch_encoder(state)
    end
  end

  defp handle_no_dispatch_encoder(state) do
    current_status = PipelineStateMachine.get_state(state.pipeline)

    if PipelineStateMachine.available_for_work?(current_status) do
      case get_next_vmaf_preview() do
        nil ->
          # No videos to process - transition to idle
          updated_pipeline = PipelineStateMachine.transition_to(state.pipeline, :idle)
          new_state = %{state | pipeline: updated_pipeline}
          {:noreply, [], new_state}

        _vmaf ->
          # VMAFs available but no demand or encoder service unavailable
          {:noreply, [], state}
      end
    else
      {:noreply, [], state}
    end
  end

  defp should_dispatch?(state) do
    current_status = PipelineStateMachine.get_state(state.pipeline)
    status_check = PipelineStateMachine.available_for_work?(current_status)
    availability_check = encoding_available?()
    result = status_check and availability_check

    Logger.debug(
      "[Encoder Producer] should_dispatch? - status: #{current_status}, status_check: #{status_check}, availability_check: #{availability_check}, result: #{result}"
    )

    result
  end

  defp encoding_available? do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        Logger.debug("Producer: encoding_available? - Encode GenServer not found")
        false

      pid ->
        # Simplified - just check if process is alive, let work fail gracefully if busy
        alive = Process.alive?(pid)
        Logger.debug("Producer: encoding_available? - Encode GenServer alive: #{alive}")
        alive
    end
  end

  defp dispatch_vmafs(state) do
    # Only transition to processing if not already processing
    current_status = PipelineStateMachine.get_state(state.pipeline)

    updated_pipeline =
      if current_status != :processing do
        Logger.info("[Encoder Producer] Transitioning to processing state from #{current_status}")
        PipelineStateMachine.start_processing(state.pipeline)
      else
        Logger.info("[Encoder Producer] Already in processing state, skipping state transition")
        state.pipeline
      end

    updated_state = %{state | pipeline: updated_pipeline}

    # Get VMAF directly from database
    case Media.get_next_for_encoding(1) do
      # Handle case where a single VMAF is returned
      %Reencodarr.Media.Vmaf{} = vmaf ->
        Logger.debug(
          "Producer: dispatch_vmafs - dispatching VMAF #{vmaf.id}, keeping demand: #{state.demand}"
        )

        final_state = %{updated_state | demand: state.demand}
        {:noreply, [vmaf], final_state}

      # Handle case where a list is returned
      [vmaf | _] ->
        Logger.debug(
          "Producer: dispatch_vmafs - dispatching VMAF #{vmaf.id}, keeping demand: #{state.demand}"
        )

        final_state = %{updated_state | demand: state.demand}
        {:noreply, [vmaf], final_state}

      # Handle case where empty list or nil is returned
      _ ->
        # No VMAF available, transition to appropriate state
        final_pipeline = PipelineStateMachine.transition_to(updated_state.pipeline, :idle)
        final_state = %{updated_state | pipeline: final_pipeline}
        {:noreply, [], final_state}
    end
  end

  # Helper to check if VMAFs are available without modifying state
  defp get_next_vmaf_preview do
    case Media.get_next_for_encoding(1) do
      # Handle case where a single VMAF is returned
      %Reencodarr.Media.Vmaf{} = vmaf -> vmaf
      # Handle case where a list is returned
      [vmaf | _] -> vmaf
      # Handle case where an empty list is returned
      [] -> nil
      # Handle case where nil is returned
      nil -> nil
    end
  end

  # Helper function to force dispatch when encoder is running
  defp force_dispatch_if_running(state) do
    current_status = PipelineStateMachine.get_state(state.pipeline)

    if PipelineStateMachine.available_for_work?(current_status) and get_next_vmaf_preview() != nil do
      Logger.debug("[Encoder Producer] Force dispatching VMAF to wake up idle Broadway pipeline")

      dispatch_if_ready(state)
    else
      {:noreply, [], state}
    end
  end
end
