defmodule Reencodarr.Analyzer.Producer do
  @moduledoc """
  GenStage producer for file analysis operations.
  
  This producer manages the queue of files that need media analysis and
  provides control functions for pausing/resuming the analysis process.
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

  # Get current manual queue for dashboard display
  def get_manual_queue do
    case process_alive?() do
      true -> GenStage.call(__MODULE__, :get_manual_queue)
      false -> []
    end
  end

  # Helper function to check if the process is alive
  defp process_alive? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      _pid -> true
    end
  end

  # Called to add a specific video for processing (e.g., force_reanalyze)
  def add_video(video_info), do: GenStage.cast(__MODULE__, {:add_video, video_info})

  @impl true
  def init(:ok) do
    # Subscribe to media events that indicate new items are available
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")

    {:producer, %{demand: 0, paused: true, manual_queue: []}}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, not state.paused, [], state}
  end

  @impl true
  def handle_call(:get_manual_queue, _from, state) do
    {:reply, state.manual_queue, [], state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("Analyzer producer paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
    :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})
    {:noreply, [], %{state | paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("Analyzer producer resumed")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :started})
    :telemetry.execute([:reencodarr, :analyzer, :started], %{}, %{})
    new_state = %{state | paused: false}
    dispatch_if_ready(new_state)
  end

  @impl true
  def handle_cast({:add_video, video_info}, state) do
    Logger.debug("Adding video to manual queue: #{video_info.path}")
    new_state = %{state | manual_queue: [video_info | state.manual_queue]}
    dispatch_if_ready(new_state)
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    dispatch_if_ready(new_state)
  end

  @impl true
  def handle_info({:video_upserted, _video}, state) do
    # New video created, might have items ready for analysis
    dispatch_if_ready(state)
  end

  def handle_info({:vmaf_upserted, _vmaf}, state) do
    # VMAF created - Analyzer doesn't need to react to this
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
    # First, dispatch any manually queued videos (e.g., force_reanalyze)
    {manual_videos, remaining_manual} = Enum.split(state.manual_queue, state.demand)

    dispatched_count = length(manual_videos)
    remaining_demand = state.demand - dispatched_count

    # If we still have demand after manual videos, get videos from the database
    database_videos =
      if remaining_demand > 0 do
        Media.get_next_for_analysis(remaining_demand)
      else
        []
      end

    all_videos = manual_videos ++ database_videos

    case all_videos do
      [] ->
        # No videos available, keep the demand for later
        {:noreply, [], state}

      videos ->
        Logger.debug(
          "Analyzer producer dispatching #{length(videos)} videos for analysis (#{dispatched_count} manual, #{length(database_videos)} from DB)"
        )

        new_demand = state.demand - length(videos)
        new_state = %{state | demand: new_demand, manual_queue: remaining_manual}
        {:noreply, videos, new_state}
    end
  end
end
