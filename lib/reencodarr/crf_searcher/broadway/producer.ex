defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Broadway producer for CRF search operations.

  This producer dispatches videos for CRF search only when the CRF search
  GenServer is available, preventing duplicate work and resource waste.
  """

  use GenStage
  require Logger
  alias Reencodarr.{Dashboard.Events, Media, PipelineStatus}

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API for external control
  def pause, do: PipelineStatus.send_to_producer(:crf_searcher, :pause)
  def resume, do: PipelineStatus.send_to_producer(:crf_searcher, :resume)
  def dispatch_available, do: PipelineStatus.send_to_producer(:crf_searcher, :dispatch_available)
  def add_video(video), do: PipelineStatus.send_to_producer(:crf_searcher, {:add_video, video})

  # Status API
  def status do
    case PipelineStatus.find_producer_process(:crf_searcher) do
      nil ->
        :stopped

      pid ->
        try do
          GenStage.call(pid, :get_state, 1000)
          |> case do
            %{status: status} -> status
            _ -> :unknown
          end
        catch
          :exit, _ -> :unknown
        end
    end
  end

  def request_status(requester_pid) do
    PipelineStatus.send_to_producer(:crf_searcher, {:status_request, requester_pid})
  end

  # Alias for API compatibility
  def start, do: resume()

  def running? do
    case PipelineStatus.find_producer_process(:crf_searcher) do
      nil ->
        false

      producer_pid ->
        try do
          GenStage.call(producer_pid, :running?, 1000)
        catch
          :exit, _ -> false
        end
    end
  end

  # Check if actively processing (for telemetry/progress updates)
  def actively_running? do
    case PipelineStatus.find_producer_process(:crf_searcher) do
      nil ->
        false

      producer_pid ->
        try do
          GenStage.call(producer_pid, :actively_running?, 1000)
        catch
          :exit, _ -> false
        end
    end
  end

  @impl GenStage
  def init(_opts) do
    # Subscribe to video state transitions for videos that finished analysis
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")

    # Send a delayed message to trigger initial telemetry emission
    Process.send_after(self(), :initial_telemetry, 1000)

    {:producer,
     %{
       demand: 0,
       status: :paused,
       queue: :queue.new()
     }}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, [], state}
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    # Button should reflect user intent - not running if paused or pausing
    # Include :idle as running since it means ready to work, just no current jobs
    running = state.status in [:running, :idle]
    {:reply, running, [], state}
  end

  @impl GenStage
  def handle_call(:actively_running?, _from, state) do
    # For telemetry/progress - actively running if processing or pausing
    # This allows progress to continue during pausing state
    actively_running = state.status in [:processing, :pausing]
    {:reply, actively_running, [], state}
  end

  @impl GenStage
  def handle_cast({:status_request, requester_pid}, state) do
    send(requester_pid, {:status_response, :crf_searcher, state.status})
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    PipelineStatus.handle_pause_cast(:crf_searcher, state)
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    PipelineStatus.handle_resume_cast(:crf_searcher, state, &dispatch_if_ready/1)
  end

  @impl GenStage
  def handle_cast({:add_video, video}, state) do
    new_queue = :queue.in(video, state.queue)
    new_state = %{state | queue: new_queue}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    PipelineStatus.handle_dispatch_available_cast(:crf_searcher, state, &dispatch_if_ready/1)
  end

  @impl GenStage
  def handle_info({:video_state_changed, video, :analyzed}, state) do
    # Video finished analysis - if CRF searcher is running, force dispatch even without demand
    Logger.debug("[CRF Searcher Producer] Received analyzed video: #{video.path}")

    Logger.debug(
      "[CRF Searcher Producer] State: #{inspect(%{status: state.status, demand: state.demand})}"
    )

    force_dispatch_if_running(state)
  end

  @impl GenStage
  def handle_info({:video_state_changed, _video, _other_state}, state) do
    # Ignore other state transitions - CRF searcher only cares about :analyzed
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:crf_search_completed, _video_id, _result}, state) do
    # CRF search completed - reset status to running if we were processing
    new_status =
      case state.status do
        :processing -> :running
        :pausing -> :paused
        other -> other
      end

    new_state = %{state | status: new_status}

    # Refresh queue telemetry and check for more work
    emit_initial_telemetry(new_state)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info(:initial_telemetry, state) do
    # Emit initial telemetry on startup to populate dashboard queue
    Logger.info("🔍 CRF Searcher: Emitting initial telemetry")
    emit_initial_telemetry(state)

    # Schedule periodic telemetry updates like the analyzer does
    Process.send_after(self(), :periodic_telemetry, 5000)

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info(:periodic_telemetry, state) do
    # Emit periodic telemetry to keep dashboard updated
    Logger.debug("🔍 CRF Searcher: Emitting periodic telemetry")
    emit_initial_telemetry(state)

    # Schedule next update
    Process.send_after(self(), :periodic_telemetry, 5000)

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # Private functions

  defp dispatch_if_ready(state) do
    if should_dispatch?(state) and state.demand > 0 do
      dispatch_videos(state)
    else
      handle_no_dispatch(state)
    end
  end

  defp handle_no_dispatch(%{status: :running} = state) do
    case get_next_video_preview() do
      nil ->
        # No videos to process - set to idle
        Logger.info("CrfSearcher going idle - no videos to process")

        # Send to Dashboard V2
        Events.broadcast_event(:crf_searcher_idle)

        new_state = %{state | status: :idle}
        {:noreply, [], new_state}

      _video ->
        # Videos available but no demand or CRF service unavailable
        {:noreply, [], state}
    end
  end

  defp handle_no_dispatch(state), do: {:noreply, [], state}

  defp should_dispatch?(state) do
    state.status == :running and crf_search_available?()
  end

  defp crf_search_available? do
    case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
      nil ->
        false

      pid ->
        try do
          case GenServer.call(pid, :running?, 1000) do
            :not_running -> true
            _ -> false
          end
        catch
          :exit, _ -> false
        end
    end
  end

  defp dispatch_videos(state) do
    if state.demand > 0 and should_dispatch?(state) do
      # Get one video from queue or database
      case get_next_video(state) do
        {nil, new_state} ->
          {:noreply, [], new_state}

        {video, new_state} ->
          Logger.info(
            "🚀 CRF Producer: Dispatching video #{video.id} (#{video.title}) for CRF search"
          )

          # Mark as processing and decrement demand
          updated_state = %{new_state | demand: state.demand - 1, status: :processing}

          # Get remaining videos for queue state update
          remaining_videos = Media.get_videos_for_crf_search(10)
          total_count = Media.count_videos_for_crf_search()

          # Emit telemetry event for queue state change
          :telemetry.execute(
            [:reencodarr, :crf_searcher, :queue_changed],
            %{
              dispatched_count: 1,
              remaining_demand: updated_state.demand,
              queue_size: total_count
            },
            %{
              next_videos: remaining_videos,
              database_queue_available: total_count > 0
            }
          )

          {:noreply, [video], updated_state}
      end
    else
      {:noreply, [], state}
    end
  end

  defp get_next_video(state) do
    case :queue.out(state.queue) do
      {{:value, video}, remaining_queue} ->
        {video, %{state | queue: remaining_queue}}

      {:empty, _queue} ->
        case Media.get_videos_for_crf_search(1) do
          [video | _] -> {video, state}
          [] -> {nil, state}
        end
    end
  end

  # Helper to check if videos are available without modifying state
  defp get_next_video_preview do
    case Media.get_videos_for_crf_search(1) do
      [video | _] -> video
      [] -> nil
    end
  end

  # Emit initial telemetry on startup to populate dashboard queues
  defp emit_initial_telemetry(state) do
    # Get 10 for dashboard display
    next_videos = get_next_videos_for_telemetry(state, 10)
    # Get total count for accurate queue size
    total_count = Media.count_videos_for_crf_search()

    Logger.debug(
      "🔍 CRF Searcher: Emitting telemetry - #{total_count} videos, #{length(next_videos)} in next batch"
    )

    measurements = %{
      queue_size: total_count
    }

    metadata = %{
      producer_type: :crf_searcher,
      # For backward compatibility
      next_video: List.first(next_videos),
      # Full list for dashboard
      next_videos: next_videos
    }

    :telemetry.execute([:reencodarr, :crf_searcher, :queue_changed], measurements, metadata)
  end

  # Get multiple next videos for dashboard display
  defp get_next_videos_for_telemetry(state, limit) do
    # First get what's in the queue
    queue_items = :queue.to_list(state.queue) |> Enum.take(limit)
    remaining_needed = limit - length(queue_items)

    # Then get additional from database if needed
    db_videos =
      if remaining_needed > 0 do
        Media.get_videos_for_crf_search(remaining_needed)
      else
        []
      end

    queue_items ++ db_videos
  end

  # Helper function to force dispatch when CRF searcher is running
  defp force_dispatch_if_running(%{status: :running} = state) do
    Logger.debug("[CRF Searcher Producer] Force dispatch - status: running")

    if crf_search_available?() do
      Logger.debug("[CRF Searcher Producer] GenServer available, getting videos...")
      videos = Media.get_videos_for_crf_search(1)

      if length(videos) > 0 do
        Logger.debug(
          "[CRF Searcher Producer] Force dispatching video to wake up idle Broadway pipeline"
        )

        {:noreply, videos, state}
      else
        {:noreply, [], state}
      end
    else
      Logger.warning("[CRF Searcher Producer] GenServer not available")
      {:noreply, [], state}
    end
  end

  defp force_dispatch_if_running(state) do
    Logger.debug(
      "[CRF Searcher Producer] Force dispatch - status: #{state.status}, falling back to dispatch_if_ready"
    )

    dispatch_if_ready(state)
  end
end
