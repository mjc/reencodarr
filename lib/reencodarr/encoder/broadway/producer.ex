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
        try do
          GenStage.call(producer_pid, :running?, 1000)
        catch
          :exit, _ -> false
        end
    end
  end

  # Check if actively processing (for telemetry/progress updates)
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
    # Subscribe to video state transitions for videos that finished CRF search
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")
    # Subscribe to encoding events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")

    # Send a delayed message to broadcast initial queue state
    Process.send_after(self(), :initial_queue_broadcast, 1000)

    {:producer,
     %{
       demand: 0,
       status: :paused,
       queue: :queue.new()
     }}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    # Only dispatch if we're not already processing something
    if state.status == :processing do
      # If we're already processing, just store the demand for later
      {:noreply, [], new_state}
    else
      dispatch_if_ready(new_state)
    end
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
  def handle_cast({:status_request, requester_pid}, state) do
    send(requester_pid, {:status_response, :encoder, state.status})
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:broadcast_status, state) do
    # Broadcast the appropriate status event based on current state
    event_name =
      case state.status do
        :processing -> :encoder_started
        # This maps to "paused" on dashboard
        :paused -> :encoder_stopped
        :pausing -> :encoder_pausing
        _ -> :encoder_idle
      end

    Events.broadcast_event(event_name, %{})
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    case state.status do
      :processing ->
        Logger.info("Encoder pausing - will finish current job and stop")
        {:noreply, [], %{state | status: :pausing}}

      _ ->
        Logger.info("Encoder paused")
        Reencodarr.Telemetry.emit_encoder_paused()
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :paused})
        {:noreply, [], %{state | status: :paused}}
    end
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("Encoder resumed")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :started})
    new_state = %{state | status: :running}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast({:add_vmaf, vmaf}, state) do
    new_queue = :queue.in(vmaf, state.queue)
    new_state = %{state | queue: new_queue}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    # Encoding completed
    case state.status do
      :pausing ->
        Logger.info("Encoder finished current job - now fully paused")
        Reencodarr.Telemetry.emit_encoder_paused()
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :paused})
        new_state = %{state | status: :paused}
        {:noreply, [], new_state}

      :idle ->
        # Transition from idle back to running when work becomes available
        new_state = %{state | status: :running}
        dispatch_if_ready(new_state)

      _ ->
        new_state = %{state | status: :running}
        dispatch_if_ready(new_state)
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
  def handle_info({:encoding_completed, vmaf_id, result}, state) do
    # Encoding completed (success or failure), transition back to running
    Logger.info(
      "Producer: Received encoding completion notification - VMAF: #{vmaf_id}, result: #{inspect(result)}"
    )

    Logger.debug("[Encoder Producer] Current state before transition - status: #{state.status}")

    new_state = %{state | status: :running}
    Logger.debug("[Encoder Producer] State after transition - status: #{new_state.status}")

    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info(:initial_queue_broadcast, state) do
    # Broadcast initial queue state so UI shows correct count on startup
    broadcast_queue_state()
    {:noreply, [], state}
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
      "Producer: dispatch_if_ready called - status: #{state.status}, demand: #{state.demand}"
    )

    if should_dispatch?(state) and state.demand > 0 do
      Logger.debug("Producer: dispatch_if_ready - conditions met, dispatching VMAFs")
      dispatch_vmafs(state)
    else
      Logger.debug("Producer: dispatch_if_ready - conditions NOT met, not dispatching")
      handle_no_dispatch_encoder(state)
    end
  end

  defp handle_no_dispatch_encoder(%{status: :running} = state) do
    case get_next_vmaf_preview() do
      nil ->
        # No videos to process - set to idle
        new_state = %{state | status: :idle}
        {:noreply, [], new_state}

      _vmaf ->
        # VMAFs available but no demand or encoder service unavailable
        {:noreply, [], state}
    end
  end

  defp handle_no_dispatch_encoder(state), do: {:noreply, [], state}

  defp should_dispatch?(state) do
    status_check = state.status == :running
    availability_check = encoding_available?()
    result = status_check and availability_check

    Logger.debug(
      "[Encoder Producer] should_dispatch? - status: #{state.status}, status_check: #{status_check}, availability_check: #{availability_check}, result: #{result}"
    )

    result
  end

  defp encoding_available? do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        Logger.debug("Producer: encoding_available? - Encode GenServer not found")
        false

      pid ->
        case GenServer.call(pid, :running?, 1000) do
          :not_running ->
            Logger.debug(
              "Producer: encoding_available? - Encode GenServer is :not_running - AVAILABLE"
            )

            true

          status when status != :not_running ->
            Logger.debug(
              "Producer: encoding_available? - Encode GenServer status: #{inspect(status)} - NOT AVAILABLE"
            )

            false
        end
    end
  end

  defp dispatch_vmafs(state) do
    # Mark as processing immediately to prevent duplicate dispatches
    updated_state = %{state | status: :processing}

    # Broadcast status change to processing
    Events.broadcast_event(:encoder_started, %{})

    # Get one VMAF from queue or database
    case get_next_vmaf(updated_state) do
      {nil, new_state} ->
        # No VMAF available, emit queue state and reset to running
        broadcast_queue_state()
        {:noreply, [], %{new_state | status: :running}}

      {vmaf, new_state} ->
        # Emit queue state update when dispatching
        broadcast_queue_state()
        # Decrement demand and keep processing status
        final_state = %{new_state | demand: state.demand - 1}

        {:noreply, [vmaf], final_state}
    end
  end

  defp get_next_vmaf(state) do
    case :queue.out(state.queue) do
      {{:value, vmaf}, remaining_queue} ->
        {vmaf, %{state | queue: remaining_queue}}

      {:empty, _queue} ->
        case Media.get_next_for_encoding(1) do
          # Handle case where a single VMAF is returned
          %Reencodarr.Media.Vmaf{} = vmaf -> {vmaf, state}
          # Handle case where a list is returned
          [vmaf | _] -> {vmaf, state}
          # Handle case where an empty list is returned
          [] -> {nil, state}
          # Handle case where nil is returned
          nil -> {nil, state}
        end
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
  defp force_dispatch_if_running(%{status: :running} = state) do
    videos = Media.get_next_for_encoding(1)

    if length(videos) > 0 do
      Logger.debug("[Encoder Producer] Force dispatching video to wake up idle Broadway pipeline")
      {:noreply, videos, state}
    else
      {:noreply, [], state}
    end
  end

  defp force_dispatch_if_running(state) do
    dispatch_if_ready(state)
  end

  # Broadcast current queue state for UI updates
  defp broadcast_queue_state do
    # Get next VMAFs for UI display
    next_vmafs = Media.list_videos_by_estimated_percent(10)

    # Format for UI display
    formatted_vmafs =
      Enum.map(next_vmafs, fn vmaf ->
        %{
          path: vmaf.video.path,
          crf: vmaf.crf,
          vmaf: vmaf.score,
          savings: vmaf.savings,
          size: vmaf.size
        }
      end)

    # Emit telemetry event that the UI expects
    measurements = %{
      queue_size: length(next_vmafs)
    }

    metadata = %{
      next_vmafs: formatted_vmafs
    }

    :telemetry.execute([:reencodarr, :encoder, :queue_changed], measurements, metadata)
  end
end
