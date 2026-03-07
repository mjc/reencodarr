defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway producer for analyzer with in-flight deduplication.

  Tracks video IDs currently being processed to prevent the same video
  from being dispatched multiple times before its state transitions.
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

  @doc """
  Removes completed video IDs from the in-flight set so they can be re-fetched if needed.
  Called by Broadway after a batch finishes processing.
  """
  def batch_completed(video_ids) when is_list(video_ids) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :producer_not_found}
      pid -> send(pid, {:batch_completed, video_ids})
    end
  end

  @impl GenStage
  def init(_opts) do
    schedule_poll()
    {:producer, %{pending_demand: 0, in_flight: MapSet.new()}}
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
  def handle_info({:batch_completed, video_ids}, state) do
    removed = MapSet.new(video_ids)
    new_in_flight = MapSet.difference(state.in_flight, removed)

    Logger.debug(
      "Analyzer: cleared #{MapSet.size(removed)} IDs from in-flight (#{MapSet.size(new_in_flight)} remaining)"
    )

    {:noreply, [], %{state | in_flight: new_in_flight}}
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(demand, state) when demand > 0 do
    # Fetch more than needed to account for in-flight filtering
    candidates =
      Media.get_videos_needing_analysis(min(demand + MapSet.size(state.in_flight), 100))

    videos = Enum.reject(candidates, &MapSet.member?(state.in_flight, &1.id))
    videos = Enum.take(videos, demand)

    new_in_flight =
      Enum.reduce(videos, state.in_flight, fn v, acc -> MapSet.put(acc, v.id) end)

    remaining_demand = demand - length(videos)

    Logger.debug(
      "Analyzer: dispatch(#{demand}) -> #{length(videos)} videos, #{remaining_demand} remaining, #{MapSet.size(new_in_flight)} in-flight"
    )

    {:noreply, videos, %{state | pending_demand: remaining_demand, in_flight: new_in_flight}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
