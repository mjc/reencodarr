defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Simplest possible Broadway producer for CRF search.
  When demand arrives, check if CrfSearch is available and return 1 video if so.
  """

  use GenStage
  require Logger

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenStage
  def init(_opts) do
    # Poll every 2 seconds to check for new work
    schedule_poll()
    {:producer, %{pending_demand: 0, consecutive_unavailable: 0}}
  end

  @impl GenStage
  def handle_demand(demand, state) do
    new_demand = state.pending_demand + demand
    dispatch(new_demand, state)
  end

  @impl GenStage
  def handle_info(:poll, state) do
    schedule_poll()
    # If there's pending demand, try to fulfill it
    dispatch(state.pending_demand, state)
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(demand, state) when demand > 0 do
    available = CrfSearch.available?()

    videos =
      if available do
        Media.get_videos_for_crf_search(1)
      else
        []
      end

    remaining_demand = demand - length(videos)

    # Track consecutive unavailable polls for auto-recovery
    new_consecutive =
      if available do
        0
      else
        state.consecutive_unavailable + 1
      end

    # After 900 consecutive unavailable polls (~30 minutes), attempt recovery
    threshold = 900

    if new_consecutive >= threshold and rem(new_consecutive, threshold) == 0 do
      Logger.warning(
        "CrfSearch has been unavailable for #{new_consecutive} consecutive polls (~#{div(new_consecutive * 2, 60)} minutes). Attempting recovery..."
      )

      CrfSearch.reset_if_stuck()
    end

    {:noreply, videos,
     %{state | pending_demand: remaining_demand, consecutive_unavailable: new_consecutive}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
