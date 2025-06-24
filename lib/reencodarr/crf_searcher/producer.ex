defmodule Reencodarr.CrfSearcher.Producer do
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

  @impl true
  def init(:ok) do
    {:producer, %{demand: 0, timer: nil, paused: true}}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, not(state.paused), state}
  end

  @impl true
  def handle_cast(:pause, state) do
    if timer = state.timer, do: Process.cancel_timer(timer)
    Logger.info("CrfSearcher producer paused")
    {:noreply, [], %{state | paused: true, timer: nil}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("CrfSearcher producer resumed")
    new_state =
      if state.demand > 0 and state.paused do
        timer = Process.send_after(self(), :dispatch, 0)
        %{state | paused: false, timer: timer}
      else
        %{state | paused: false}
      end
    {:noreply, [], new_state}
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    new_demand = state.demand + demand

    new_state =
      if is_nil(state.timer) and not state.paused and new_demand > 0 do
        timer = Process.send_after(self(), :dispatch, 0)  # Dispatch immediately for new demand
        %{state | demand: new_demand, timer: timer}
      else
        %{state | demand: new_demand}
      end

    {:noreply, [], new_state}
  end

  @impl true
  def handle_info(:dispatch, state) do
    if state.paused do
      {:noreply, [], %{state | timer: nil}}
    else
      videos = Media.get_next_crf_search(state.demand)
      new_demand = state.demand - length(videos)

      if length(videos) > 0 do
        Logger.debug("CrfSearcher producer dispatching #{length(videos)} videos for CRF search")
      end

      new_state =
        if new_demand > 0 do
          timer = Process.send_after(self(), :dispatch, 5000)
          %{state | demand: new_demand, timer: timer}
        else
          %{state | demand: 0, timer: nil}
        end

      {:noreply, videos, new_state}
    end
  end
end
