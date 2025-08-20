defmodule Reencodarr.Encoder.Broadway.Producer do
  @moduledoc """
  Broadway producer for encoding operations.

  This producer dispatches VMAFs for encoding only when the encoding
  GenServer is available, preventing duplicate work and resource waste.
  """

  use GenStage
  require Logger
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
    # Subscribe to media events for new VMAFs
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to encoding events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")

    # Send a delayed message to trigger initial telemetry emission
    Process.send_after(self(), :initial_telemetry, 1000)

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

      _ ->
        new_state = %{state | status: :running}
        dispatch_if_ready(new_state)
    end
  end

  @impl GenStage
  def handle_info({:vmaf_upserted, _vmaf}, state) do
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info({:encoding_completed, _vmaf_id, _result}, state) do
    # Encoding completed - reset status to running if we were processing
    new_status =
      case state.status do
        :processing -> :running
        :pausing -> :paused
        other -> other
      end

    new_state = %{state | status: new_status}

    # Refresh queue telemetry and check for more work
    emit_initial_telemetry(new_state)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info(:initial_telemetry, state) do
    # Emit initial telemetry on startup to populate dashboard queue
    emit_initial_telemetry(state)
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
      {:noreply, [], state}
    end
  end

  defp should_dispatch?(state) do
    status_check = state.status == :running
    availability_check = encoding_available?()
    result = status_check and availability_check

    Logger.debug(
      "Producer: should_dispatch? - status: #{state.status}, status_check: #{status_check}, availability_check: #{availability_check}, result: #{result}"
    )

    result
  end

  defp encoding_available? do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        Logger.debug("Producer: encoding_available? - Encode GenServer not found")
        false

      pid ->
        try do
          case GenServer.call(pid, :running?, 1000) do
            :not_running ->
              Logger.debug(
                "Producer: encoding_available? - Encode GenServer is :not_running - AVAILABLE"
              )

              true

            status ->
              Logger.debug(
                "Producer: encoding_available? - Encode GenServer status: #{inspect(status)} - NOT AVAILABLE"
              )

              false
          end
        catch
          :exit, reason ->
            Logger.debug(
              "Producer: encoding_available? - Encode GenServer call failed: #{inspect(reason)}"
            )

            false
        end
    end
  end

  defp dispatch_vmafs(state) do
    # Mark as processing immediately to prevent duplicate dispatches
    updated_state = %{state | status: :processing}

    # Get one VMAF from queue or database
    case get_next_vmaf(updated_state) do
      {nil, new_state} ->
        # No VMAF available, reset to running
        {:noreply, [], %{new_state | status: :running}}

      {vmaf, new_state} ->
        # Decrement demand and keep processing status
        final_state = %{new_state | demand: state.demand - 1}

        # Get remaining vmafs for queue state update
        remaining_vmafs = Media.get_next_for_encoding(10)
        total_count = Media.encoding_queue_count()

        # Emit telemetry event for queue state change
        :telemetry.execute(
          [:reencodarr, :encoder, :queue_changed],
          %{dispatched_count: 1, remaining_demand: final_state.demand, queue_size: total_count},
          %{
            next_vmafs: remaining_vmafs,
            database_queue_available: total_count > 0
          }
        )

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

  # Emit initial telemetry on startup to populate dashboard queues
  defp emit_initial_telemetry(state) do
    # Get 5 for dashboard display
    next_vmafs = get_next_vmafs_for_telemetry(state, 5)
    # Get total count for accurate queue size
    total_count = Media.encoding_queue_count()

    measurements = %{
      queue_size: total_count
    }

    metadata = %{
      producer_type: :encoder,
      # For backward compatibility
      next_vmaf: List.first(next_vmafs),
      # Full list for dashboard
      next_vmafs: next_vmafs
    }

    :telemetry.execute([:reencodarr, :encoder, :queue_changed], measurements, metadata)
  end

  # Get multiple next VMAFs for dashboard display
  defp get_next_vmafs_for_telemetry(state, limit) do
    # First get what's in the queue
    queue_items = :queue.to_list(state.queue) |> Enum.take(limit)
    remaining_needed = limit - length(queue_items)

    # Then get additional from database if needed
    db_vmafs =
      if remaining_needed > 0 do
        case Media.get_next_for_encoding(remaining_needed) do
          list when is_list(list) -> list
          single_item when not is_nil(single_item) -> [single_item]
          nil -> []
        end
      else
        []
      end

    queue_items ++ db_vmafs
  end
end
