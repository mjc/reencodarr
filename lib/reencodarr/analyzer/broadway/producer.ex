defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Simplest possible Broadway producer for analyzer.
  Just fetch videos and return them - no pause/resume, no state machine.
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
    # Poll every 2 seconds to check for new work
    schedule_poll()
    {:producer, %{pending_demand: 0}}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    # Accumulate demand and fetch videos
    new_demand = state.pending_demand + demand
    dispatch(new_demand, state)
  end

  @impl GenStage
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_info(:poll, state) do
    schedule_poll()
    # If there's pending demand, try to fulfill it
    # This wakes up Broadway when new work appears
    dispatch(state.pending_demand, state)
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(demand, state) when demand > 0 do
    # Fetch up to 5 videos for batch processing
    videos = Media.get_videos_needing_analysis(min(demand, 5))
    remaining_demand = demand - length(videos)

    Logger.debug(
      "Analyzer: dispatch(#{demand}) -> #{length(videos)} videos, #{remaining_demand} remaining"
    )

    {:noreply, videos, %{state | pending_demand: remaining_demand}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
