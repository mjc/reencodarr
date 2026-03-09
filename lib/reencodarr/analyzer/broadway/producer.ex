defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway producer for the analyzer pipeline.

  Uses atomic state transitions (needs_analysis → analyzing) to claim videos
  at the database level, preventing race conditions without in-memory tracking.
  """

  use GenStage
  require Logger
  alias Reencodarr.Media

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def dispatch_available do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :producer_not_found}
      pid -> send(pid, :poll)
    end
  end

  @impl GenStage
  def init(_opts) do
    schedule_poll()
    {:producer, %{pending_demand: 0}}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    new_demand = state.pending_demand + demand
    dispatch(new_demand, state)
  end

  @impl GenStage
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_info(:poll, state) do
    schedule_poll()
    dispatch(state.pending_demand, state)
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(demand, state) when demand > 0 do
    videos = Media.claim_videos_for_analysis(demand)
    remaining_demand = demand - length(videos)

    if videos != [] do
      Logger.debug(
        "Analyzer: claimed #{length(videos)} videos, #{remaining_demand} demand remaining"
      )
    end

    {:noreply, videos, %{state | pending_demand: remaining_demand}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
