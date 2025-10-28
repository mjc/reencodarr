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
    {:producer, %{}}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    # Fetch up to 5 videos for batch processing
    videos = Media.get_videos_needing_analysis(min(demand, 5))
    Logger.debug("Analyzer: handle_demand(#{demand}) -> #{length(videos)} videos")
    {:noreply, videos, state}
  end

  @impl GenStage
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_info(:poll, state) do
    schedule_poll()
    # Check if there's work and manually ask Broadway to pull
    case Media.count_videos_needing_analysis() do
      0 ->
        {:noreply, [], state}

      _count ->
        # There's work available - return one video to wake up Broadway
        videos = Media.get_videos_needing_analysis(1)
        Logger.debug("Analyzer: poll wakeup -> #{length(videos)} videos")
        {:noreply, videos, state}
    end
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
