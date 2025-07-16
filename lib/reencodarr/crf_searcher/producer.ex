defmodule Reencodarr.CrfSearcher.Producer do
  @moduledoc """
  GenStage producer for CRF search operations.

  This producer manages the queue of videos that need CRF searches and
  provides control functions for pausing/resuming the search process.
  """

  use GenStage
  require Logger
  alias Reencodarr.Media

  def start_link do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def pause, do: GenStage.cast(__MODULE__, :pause)
  def resume, do: GenStage.cast(__MODULE__, :resume)
  # Alias for API compatibility
  def start, do: GenStage.cast(__MODULE__, :resume)

  def running? do
    case process_alive?() do
      true -> GenStage.call(__MODULE__, :running?)
      false -> false
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
    Reencodarr.Telemetry.emit_crf_search_paused()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :paused})
    {:noreply, [], %{state | paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("CrfSearcher producer resumed")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :started})
    new_state = %{state | paused: false}
    dispatch_if_ready(new_state)
  end

  @impl true
  def handle_cast(:dispatch_available, state) do
    dispatch_if_ready(state)
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    dispatch_if_ready(new_state)
  end

  @impl true
  def handle_info({:video_upserted, _video}, state) do
    dispatch_if_ready(state)
  end

  def handle_info({:vmaf_upserted, _vmaf}, state) do
    # VMAF created (CRF search completed) - CrfSearcher doesn't need to react to this
    {:noreply, [], state}
  end

  def handle_info(_msg, state) do
    # Ignore other PubSub messages
    {:noreply, [], state}
  end

  # Helper function to reduce duplication
  defp dispatch_if_ready(state) do
    if should_dispatch?(state) do
      dispatch_videos(state)
    else
      {:noreply, [], state}
    end
  end

  defp should_dispatch?(state) do
    not state.paused and state.demand > 0
  end

  defp dispatch_videos(state) do
    videos = Media.get_videos_for_crf_search(state.demand)

    case videos do
      [] ->
        Logger.debug("CrfSearcher producer: no videos available, demand: #{state.demand}")
        {:noreply, [], state}

      videos ->
        Logger.debug(
          "CrfSearcher producer dispatching #{length(videos)} videos for CRF search (demand: #{state.demand})"
        )

        Enum.each(videos, fn video ->
          Logger.debug("  - Video #{video.id}: #{video.path}")
        end)

        new_demand = state.demand - length(videos)
        new_state = %{state | demand: new_demand}
        {:noreply, videos, new_state}
    end
  end

  # Helper function to check if the process is alive
  defp process_alive? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      _pid -> true
    end
  end
end
