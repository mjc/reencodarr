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

  @impl GenStage
  def init(_opts) do
    # Subscribe to media events for new VMAFs
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to encoding events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoding_events")

    {:producer,
     %{
       demand: 0,
       paused: true,
       queue: :queue.new(),
       # Track if we're currently processing a VMAF
       processing: false
     }}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    # Only dispatch if we're not already processing something
    if state.processing do
      # If we're already processing, just store the demand for later
      {:noreply, [], new_state}
    else
      dispatch_if_ready(new_state)
    end
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    {:reply, not state.paused, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    Logger.info("Encoder paused")
    Reencodarr.Telemetry.emit_encoder_paused()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :paused})
    {:noreply, [], %{state | paused: true}}
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("Encoder resumed")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :started})
    new_state = %{state | paused: false}
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
    # Encoding completed, mark as not processing and try to dispatch next
    new_state = %{state | processing: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info({:vmaf_upserted, _vmaf}, state) do
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info({:encoding_completed, _vmaf_id, _result}, state) do
    # Encoding completed (success or failure), mark as not processing and try to dispatch next
    Logger.info("Producer: Received encoding completion notification")
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
    if should_dispatch?(state) and state.demand > 0 do
      dispatch_vmafs(state)
    else
      {:noreply, [], state}
    end
  end

  defp should_dispatch?(state) do
    result = not state.paused and not state.processing and encoding_available?()

    Logger.info(
      "should_dispatch? paused: #{state.paused}, processing: #{state.processing}, encoding_available: #{encoding_available?()}, result: #{result}"
    )

    result
  end

  defp encoding_available? do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        false

      pid ->
        try do
          case GenServer.call(pid, :running?, 1000) do
            :not_running -> true
            _ -> false
          end
        catch
          :exit, _ -> false
        end
    end
  end

  defp dispatch_vmafs(state) do
    Logger.info(
      "dispatch_vmafs called with processing: #{state.processing}, demand: #{state.demand}"
    )

    # Mark as processing immediately to prevent duplicate dispatches
    updated_state = %{state | processing: true}
    Logger.info("Setting processing: true")

    # Get one VMAF from queue or database
    case get_next_vmaf(updated_state) do
      {nil, new_state} ->
        Logger.info("No VMAF available, resetting processing flag")
        # No VMAF available, reset processing flag
        {:noreply, [], %{new_state | processing: false}}

      {vmaf, new_state} ->
        Logger.info("Dispatching VMAF #{vmaf.id} for encoding")
        # Decrement demand but keep processing: true
        final_state = %{new_state | demand: state.demand - 1}

        Logger.info(
          "Final state: processing: #{final_state.processing}, demand: #{final_state.demand}"
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
end
