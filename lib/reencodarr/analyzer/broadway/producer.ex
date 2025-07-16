defmodule Reencodarr.Analyzer.Broadway.Producer do
  @moduledoc """
  Broadway producer for analyzer operations.

  This producer dispatches videos for analysis in batches of up to 5,
  managing demand and batch processing for optimal mediainfo usage.
  """

  use GenStage
  require Logger
  alias Reencodarr.{Media, Telemetry}

  @broadway_name Reencodarr.Analyzer.Broadway

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API for external control
  def pause, do: send_to_producer(:pause)
  def resume, do: send_to_producer(:resume)
  def dispatch_available, do: send_to_producer(:dispatch_available)
  def add_video(video_info), do: send_to_producer({:add_video, video_info})

  # Alias for API compatibility
  def start, do: resume()

  def running? do
    case find_producer_process() do
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

  @impl GenStage
  def init(_opts) do
    # Subscribe to media events for new videos
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to analyzer events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer_events")

    {:producer,
     %{
       demand: 0,
       paused: true,
       queue: :queue.new(),
       # Track if we're currently processing videos
       processing: false
     }}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    # Only dispatch if we're not already processing something
    if state.processing do
      # If we're already processing, just store the demand for later
      {:noreply, [], new_state}
    else
      dispatch_if_ready(new_state)
    end
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    {:reply, not state.paused, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    Logger.info("Analyzer paused")
    Telemetry.emit_analyzer_paused()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
    {:noreply, [], %{state | paused: true}}
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("Analyzer resumed")
    Telemetry.emit_analyzer_started()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :started})
    new_state = %{state | paused: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast({:add_video, video_info}, state) do
    new_queue = :queue.in(video_info, state.queue)
    new_state = %{state | queue: new_queue}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    # Analysis completed, mark as not processing and try to dispatch next
    new_state = %{state | processing: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info({:video_upserted, _video}, state) do
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_info({:analysis_completed, _path, _result}, state) do
    # Individual analysis completed - this is handled by batch completion now
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:batch_analysis_completed, _batch_size}, state) do
    # Batch analysis completed, mark as not processing and try to dispatch next
    Logger.debug("Producer: Received batch analysis completion notification")
    new_state = %{state | processing: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # Private functions

  defp send_to_producer(message) do
    case find_producer_process() do
      nil -> {:error, :producer_not_found}
      producer_pid -> GenStage.cast(producer_pid, message)
    end
  end

  defp find_producer_process do
    producer_supervisor_name = :"#{@broadway_name}.Broadway.ProducerSupervisor"

    with pid when is_pid(pid) <- Process.whereis(producer_supervisor_name),
         children <- Supervisor.which_children(pid),
         producer_pid when is_pid(producer_pid) <- find_actual_producer(children) do
      producer_pid
    else
      _ -> nil
    end
  end

  defp find_actual_producer(children) do
    Enum.find_value(children, fn {_id, pid, _type, _modules} ->
      if is_pid(pid) do
        try do
          GenStage.call(pid, :running?, 1000)
          pid
        catch
          :exit, _ -> nil
        end
      end
    end)
  end

  defp dispatch_if_ready(state) do
    if should_dispatch?(state) and state.demand > 0 do
      dispatch_videos(state)
    else
      {:noreply, [], state}
    end
  end

  defp should_dispatch?(state) do
    result = not state.paused and not state.processing

    Logger.debug(
      "should_dispatch? paused: #{state.paused}, processing: #{state.processing}, result: #{result}"
    )

    result
  end

  defp dispatch_videos(state) do
    Logger.debug(
      "dispatch_videos called with processing: #{state.processing}, demand: #{state.demand}"
    )

    # Mark as processing immediately to prevent duplicate dispatches
    updated_state = %{state | processing: true}
    Logger.debug("Setting processing: true")

    # Get up to 5 videos from queue or database for batching
    case get_next_videos(updated_state, min(state.demand, 5)) do
      {[], new_state} ->
        Logger.debug("No videos available, resetting processing flag")
        # No videos available, reset processing flag
        {:noreply, [], %{new_state | processing: false}}

      {videos, new_state} ->
        video_count = length(videos)
        Logger.debug("Dispatching #{video_count} videos for analysis")
        # Decrement demand but keep processing: true
        final_state = %{new_state | demand: state.demand - video_count}

        Logger.debug(
          "Final state: processing: #{final_state.processing}, demand: #{final_state.demand}"
        )

        {:noreply, videos, final_state}
    end
  end

  defp get_next_videos(state, max_count) do
    # First, get videos from the manual queue
    {queue_videos, remaining_queue} = take_from_queue(state.queue, max_count)
    new_state = %{state | queue: remaining_queue}

    remaining_needed = max_count - length(queue_videos)

    if remaining_needed > 0 do
      # Get additional videos from database
      db_videos = Media.get_videos_needing_analysis(remaining_needed)
      all_videos = queue_videos ++ db_videos
      {all_videos, new_state}
    else
      {queue_videos, new_state}
    end
  end

  defp take_from_queue(queue, max_count) do
    take_from_queue(queue, max_count, [])
  end

  defp take_from_queue(queue, 0, acc) do
    {Enum.reverse(acc), queue}
  end

  defp take_from_queue(queue, count, acc) when count > 0 do
    case :queue.out(queue) do
      {{:value, video}, remaining_queue} ->
        take_from_queue(remaining_queue, count - 1, [video | acc])

      {:empty, _queue} ->
        {Enum.reverse(acc), queue}
    end
  end
end
