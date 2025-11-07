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
    {:producer, %{pending_demand: 0}}
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
    videos =
      if CrfSearch.available?() do
        Media.get_videos_for_crf_search(1)
      else
        []
      end

    remaining_demand = demand - length(videos)
    {:noreply, videos, %{state | pending_demand: remaining_demand}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
