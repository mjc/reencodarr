defmodule Reencodarr.CrfSearcher.Producer do
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
    Logger.info("CrfSearcher producer paused")
    {:noreply, [], %{state | paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("CrfSearcher producer resumed")
    new_state = %{state | paused: false}
    # Try to fulfill any pending demand immediately
    if new_state.demand == 0 do
      {:noreply, [], new_state}
    else
      # Fulfill up to the current demand
      videos = Media.get_next_crf_search(new_state.demand)

      if length(videos) > 0 do
        Logger.debug("CrfSearcher producer dispatching #{length(videos)} videos for CRF search")
        new_demand = new_state.demand - length(videos)
        final_state = %{new_state | demand: new_demand}
        {:noreply, videos, final_state}
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
      # Fulfill up to the current demand
      videos = Media.get_next_crf_search(state.demand)

      if length(videos) > 0 do
        Logger.debug("CrfSearcher producer dispatching #{length(videos)} videos for CRF search")
        new_demand = state.demand - length(videos)
        new_state = %{state | demand: new_demand}
        {:noreply, videos, new_state}
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
      # Fulfill up to the current demand
      videos = Media.get_next_crf_search(new_state.demand)

      if length(videos) > 0 do
        Logger.debug("CrfSearcher producer dispatching #{length(videos)} videos for CRF search")
        final_demand = new_state.demand - length(videos)
        final_state = %{new_state | demand: final_demand}
        {:noreply, videos, final_state}
      else
        # No items available, keep the demand for later
        {:noreply, [], new_state}
      end
    end
  end

  @impl true
  def handle_info({:video_upserted, _video}, state) do
    # New video created, might need CRF search
    if state.paused or state.demand == 0 do
      {:noreply, [], state}
    else
      # Fulfill up to the current demand
      videos = Media.get_next_crf_search(state.demand)

      if length(videos) > 0 do
        Logger.debug("CrfSearcher producer dispatching #{length(videos)} videos for CRF search")
        new_demand = state.demand - length(videos)
        new_state = %{state | demand: new_demand}
        {:noreply, videos, new_state}
      else
        # No items available, keep the demand for later
        {:noreply, [], state}
      end
    end
  end

  @impl true
  def handle_info({:vmaf_upserted, _vmaf}, state) do
    # VMAF created (CRF search completed) - CrfSearcher doesn't need to react to this
    {:noreply, [], state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore other PubSub messages
    {:noreply, [], state}
  end
end
