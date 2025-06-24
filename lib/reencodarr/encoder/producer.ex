defmodule Reencodarr.Encoder.Producer do
  use GenStage
  require Logger
  alias Reencodarr.Media

  def start_link() do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def pause, do: GenStage.cast(__MODULE__, :pause)
  def resume, do: GenStage.cast(__MODULE__, :resume)
  # Alias for API compatibility
  def start, do: GenStage.cast(__MODULE__, :resume)

  def running? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> GenStage.call(pid, :running?)
    end
  end

  # Called when new items become available
  def dispatch_available, do: GenStage.cast(__MODULE__, :dispatch_available)

  @impl true
  def init(:ok) do
    # Subscribe to media events that indicate new items are available
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    {:producer, %{demand: 0, paused: true}}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, not state.paused, [], state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("Encoder producer paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :paused})
    {:noreply, [], %{state | paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("Encoder producer resumed")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :started})
    new_state = %{state | paused: false}
    # Try to fulfill any pending demand immediately
    if new_state.demand == 0 do
      {:noreply, [], new_state}
    else
      # Get items up to the current demand
      items = Media.get_next_for_encoding(new_state.demand)

      # Convert single item to list if needed for consistency
      vmafs = if is_list(items), do: items, else: if(items, do: [items], else: [])

      if length(vmafs) > 0 do
        Logger.debug("Encoder producer dispatching #{length(vmafs)} videos for encoding")
        new_demand = new_state.demand - length(vmafs)
        final_state = %{new_state | demand: new_demand}
        {:noreply, vmafs, final_state}
      else
        # No items available, keep the demand for later
        {:noreply, [], new_state}
      end
    end
  end

  @impl true
  def handle_cast(:dispatch_available, state) do
    # External trigger that new items might be available
    if state.paused or state.demand == 0 do
      {:noreply, [], state}
    else
      # Get items up to the current demand
      items = Media.get_next_for_encoding(state.demand)

      # Convert single item to list if needed for consistency
      vmafs = if is_list(items), do: items, else: if(items, do: [items], else: [])

      if length(vmafs) > 0 do
        Logger.debug("Encoder producer dispatching #{length(vmafs)} videos for encoding")
        new_demand = state.demand - length(vmafs)
        new_state = %{state | demand: new_demand}
        {:noreply, vmafs, new_state}
      else
        # No items available, keep the demand for later
        {:noreply, [], state}
      end
    end
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}

    if new_state.paused or new_state.demand == 0 do
      {:noreply, [], new_state}
    else
      # Get items up to the current demand
      items = Media.get_next_for_encoding(new_state.demand)

      # Convert single item to list if needed for consistency
      vmafs = if is_list(items), do: items, else: if(items, do: [items], else: [])

      if length(vmafs) > 0 do
        Logger.debug("Encoder producer dispatching #{length(vmafs)} videos for encoding")
        final_demand = new_state.demand - length(vmafs)
        final_state = %{new_state | demand: final_demand}
        {:noreply, vmafs, final_state}
      else
        # No items available, keep the demand for later
        {:noreply, [], new_state}
      end
    end
  end

  @impl true
  def handle_info({:vmaf_upserted, _vmaf}, state) do
    # New VMAF created, might have items ready for encoding
    if state.paused or state.demand == 0 do
      {:noreply, [], state}
    else
      # Get items up to the current demand
      items = Media.get_next_for_encoding(state.demand)

      # Convert single item to list if needed for consistency
      vmafs = if is_list(items), do: items, else: if(items, do: [items], else: [])

      if length(vmafs) > 0 do
        Logger.debug("Encoder producer dispatching #{length(vmafs)} videos for encoding")
        new_demand = state.demand - length(vmafs)
        new_state = %{state | demand: new_demand}
        {:noreply, vmafs, new_state}
      else
        # No items available, keep the demand for later
        {:noreply, [], state}
      end
    end
  end

  def handle_info(_msg, state) do
    # Ignore other PubSub messages
    {:noreply, [], state}
  end
end
