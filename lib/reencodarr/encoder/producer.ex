defmodule Reencodarr.Encoder.Producer do
  use GenStage
  require Logger
  alias Reencodarr.Media

  def start_link() do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def pause, do: GenStage.cast(__MODULE__, :pause)
  def resume, do: GenStage.cast(__MODULE__, :resume)
  def start, do: GenStage.cast(__MODULE__, :resume)  # Alias for API compatibility

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
    {:reply, not(state.paused), state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("Encoder producer paused")
    {:noreply, [], %{state | paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("Encoder producer resumed")
    new_state = %{state | paused: false}
    # Try to fulfill any pending demand immediately
    fulfill_demand(new_state)
  end

  @impl true
  def handle_cast(:dispatch_available, state) do
    # External trigger that new items might be available
    fulfill_demand(state)
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    fulfill_demand(new_state)
  end

  @impl true
  def handle_info({:vmaf_upserted, _vmaf}, state) do
    # New VMAF created, might have items ready for encoding
    fulfill_demand(state)
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore other PubSub messages
    {:noreply, [], state}
  end

  defp fulfill_demand(state) do
    if state.paused or state.demand == 0 do
      {:noreply, [], state}
    else
      case Media.get_next_for_encoding() do
        nil ->
          # No items available, keep the demand for later
          {:noreply, [], state}

        vmaf ->
          Logger.debug("Encoder producer dispatching video #{vmaf.video.path} for encoding")
          new_demand = state.demand - 1
          new_state = %{state | demand: new_demand}

          # If we still have demand, try to fulfill more immediately
          if new_demand > 0 do
            fulfill_demand_continue(new_state, [vmaf])
          else
            {:noreply, [vmaf], new_state}
          end
      end
    end
  end

  defp fulfill_demand_continue(state, events) do
    case Media.get_next_for_encoding() do
      nil ->
        {:noreply, Enum.reverse(events), state}

      vmaf ->
        Logger.debug("Encoder producer dispatching video #{vmaf.video.path} for encoding")
        new_demand = state.demand - 1
        new_state = %{state | demand: new_demand}
        new_events = [vmaf | events]

        if new_demand > 0 do
          fulfill_demand_continue(new_state, new_events)
        else
          {:noreply, Enum.reverse(new_events), new_state}
        end
    end
  end
end
