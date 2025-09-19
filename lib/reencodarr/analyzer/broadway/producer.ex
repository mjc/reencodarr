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

  defmodule State do
    @moduledoc false
    defstruct [
      :demand,
      :status,
      :queue,
      :manual_queue,
      :paused,
      :processing,
      :pending_videos
    ]

    def update(state, updates) when is_struct(state, __MODULE__) do
      struct(state, updates)
    end

    def update(state, updates) when is_map(state) do
      # Handle case where state is a plain map (e.g., after crash/restart)
      # Convert it to a proper State struct first
      state_struct = struct(__MODULE__, state)
      struct(state_struct, updates)
    end
  end

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API for external control
  def pause, do: send_to_producer(:pause)
  def resume, do: send_to_producer(:resume)
  def dispatch_available, do: send_to_producer(:dispatch_available)
  def add_video(video_info), do: send_to_producer({:add_video, video_info})

  # Status API
  def status do
    case GenServer.call(__MODULE__, :get_state) do
      %{status: status} -> status
      _ -> :unknown
    end
  end

  def request_status(requester_pid) do
    GenServer.cast(__MODULE__, {:status_request, requester_pid})
  end

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

  def actively_running? do
    case find_producer_process() do
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
    # Subscribe to media events for new videos
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")
    # Subscribe to video state transitions for new videos needing analysis
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")
    # Subscribe to analyzer events to know when processing completes
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer_events")

    # Send a delayed message to trigger initial dispatch
    Process.send_after(self(), :initial_dispatch, 1000)

    {:producer,
     %State{
       demand: 0,
       status: :paused,
       queue: :queue.new(),
       manual_queue: []
     }}
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    # Button should reflect user intent - not running if paused or pausing
    running = state.status == :running
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
  def handle_call(:get_state, _from, state) do
    {:reply, state, [], state}
  end

  @impl GenStage
  def handle_cast({:status_request, requester_pid}, state) do
    send(requester_pid, {:status_response, :analyzer, state.status})
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    case state.status do
      :processing ->
        Logger.info("Analyzer pausing - will finish current batch and stop")

        # Send to Dashboard V2 - immediate pausing state for UI feedback
        alias Reencodarr.Dashboard.Events
        Events.analyzer_pausing()

        {:noreply, [], State.update(state, status: :pausing)}

      _ ->
        Logger.info("Analyzer paused")
        Telemetry.emit_analyzer_paused()
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
        :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})

        # Send to Dashboard V2
        alias Reencodarr.Dashboard.Events
        Events.analyzer_stopped()

        {:noreply, [], State.update(state, status: :paused)}
    end
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("Analyzer resumed")
    Telemetry.emit_analyzer_started()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :started})
    :telemetry.execute([:reencodarr, :analyzer, :started], %{}, %{})

    # Send to Dashboard V2
    alias Reencodarr.Dashboard.Events
    Events.analyzer_started()
    # Start with minimal progress to indicate activity
    Events.analyzer_progress(0, 1)

    new_state = State.update(state, status: :running)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast({:add_video, video_info}, state) do
    Logger.info("Adding video to Broadway queue: #{video_info.path}")
    Logger.debug("video info details", video_info: video_info)

    Logger.debug(
      "Current state - demand: #{state.demand}, status: #{state.status}, queue size: #{length(state.manual_queue)}"
    )

    new_manual_queue = [video_info | state.manual_queue]
    new_state = State.update(state, manual_queue: new_manual_queue)
    Logger.debug("After adding - queue size: #{length(new_state.manual_queue)}")

    # Broadcast queue state change
    broadcast_queue_state(new_state.manual_queue)

    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    # Trigger dispatch to check for videos that need analysis
    dispatch_if_ready(state)
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    Logger.debug("Broadway producer received demand for #{demand} items")
    new_state = State.update(state, demand: state.demand + demand)
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info({:video_upserted, _video}, state) do
    # New video was upserted - force dispatch to wake up idle Broadway
    force_dispatch_if_running(state)
  end

  @impl GenStage
  def handle_info({:video_state_changed, video, :needs_analysis}, state) do
    # Video needs analysis - if analyzer is running, force dispatch even without demand
    Logger.debug("[Analyzer Producer] Received video needing analysis: #{video.path}")
    force_dispatch_if_running(state)
  end

  @impl GenStage
  def handle_info({:analysis_completed, _path, _result}, state) do
    # Individual analysis completed - this is handled by batch completion now
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:batch_analysis_completed, _batch_size}, state) do
    # Batch analysis completed
    Logger.debug("Producer: Received batch analysis completion notification")

    case state.status do
      :pausing ->
        Logger.info("Analyzer finished current batch - now fully paused")
        Telemetry.emit_analyzer_paused()
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :paused})
        :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})

        # Send to Dashboard V2
        alias Reencodarr.Dashboard.Events
        Events.analyzer_stopped()

        new_state = State.update(state, status: :paused)
        {:noreply, [], new_state}

      _ ->
        new_state = State.update(state, status: :running)
        dispatch_if_ready(new_state)
    end
  end

  @impl GenStage
  def handle_info(:initial_dispatch, state) do
    # Trigger initial dispatch after startup to check for videos needing analysis
    Logger.debug("Producer: Initial dispatch triggered")
    # Broadcast initial queue state so UI shows correct count on startup
    broadcast_queue_state(state.manual_queue)
    dispatch_if_ready(state)
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
    Logger.debug(
      "dispatch_if_ready called - demand: #{state.demand}, status: #{state.status}, queue size: #{length(state.manual_queue)}"
    )

    case can_dispatch?(state) do
      {:auto_start, state} -> handle_auto_start(state)
      {:resume_idle, state} -> handle_resume_from_idle(state)
      {:dispatch, state} -> dispatch_videos(state)
      {:no_dispatch, state} -> handle_no_dispatch_conditions(state)
    end
  end

  defp can_dispatch?(state) do
    cond do
      ready_for_auto_start?(state) -> {:auto_start, state}
      ready_for_resume_from_idle?(state) -> {:resume_idle, state}
      ready_for_dispatch?(state) -> {:dispatch, state}
      true -> {:no_dispatch, state}
    end
  end

  defp ready_for_auto_start?(state) do
    state.status == :paused and state.demand > 0 and length(state.manual_queue) > 0
  end

  defp ready_for_resume_from_idle?(state) do
    state.status == :idle and state.demand > 0 and length(state.manual_queue) > 0
  end

  defp ready_for_dispatch?(state) do
    state.status == :running and state.demand > 0
  end

  defp handle_auto_start(state) do
    Logger.info("Auto-starting analyzer - videos available for processing")
    Telemetry.emit_analyzer_started()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :started})
    :telemetry.execute([:reencodarr, :analyzer, :started], %{}, %{})

    # Send to Dashboard V2
    alias Reencodarr.Dashboard.Events
    Events.analyzer_started()
    # Start with minimal progress to indicate activity
    Events.analyzer_progress(0, 1)

    new_state = State.update(state, status: :running)
    dispatch_videos(new_state)
  end

  defp handle_resume_from_idle(state) do
    Logger.info("Analyzer resuming from idle - videos available for processing")

    # Send to Dashboard V2
    alias Reencodarr.Dashboard.Events
    # Start with minimal progress to indicate activity
    Events.analyzer_progress(0, 1)

    new_state = State.update(state, status: :running)
    dispatch_videos(new_state)
  end

  defp handle_no_dispatch_conditions(state) do
    Logger.debug(
      "Conditions not met for dispatch - demand: #{state.demand}, queue: #{length(state.manual_queue)}"
    )

    # If analyzer is running but has no work to do, set to idle instead of paused
    if state.status == :running and state.demand == 0 and Enum.empty?(state.manual_queue) do
      handle_idle_transition(state)
    else
      {:noreply, [], state}
    end
  end

  defp handle_idle_transition(state) do
    # Check if there are any videos needing analysis in the database
    database_queue_count = Reencodarr.Media.count_videos_needing_analysis()

    if database_queue_count == 0 do
      Logger.debug("Analyzer has no work - setting to idle")
      # Set to idle - ready to work but no current tasks
      new_state = State.update(state, status: :idle)
      {:noreply, [], new_state}
    else
      Logger.debug(
        "Analyzer has #{database_queue_count} videos to analyze but no demand - staying running"
      )

      {:noreply, [], state}
    end
  end

  defp broadcast_queue_state(manual_queue) do
    # Get next videos for UI display (combine manual + database queued)
    database_videos = Media.get_videos_needing_analysis(10)
    all_next_videos = (manual_queue ++ database_videos) |> Enum.take(10)

    # Format for UI display
    next_videos =
      Enum.map(all_next_videos, fn video ->
        %{
          path: video.path,
          service_id: video.service_id || "unknown"
        }
      end)

    # Emit telemetry event that the UI expects
    measurements = %{
      queue_size: length(manual_queue) + Media.count_videos_needing_analysis()
    }

    metadata = %{
      next_videos: next_videos
    }

    :telemetry.execute([:reencodarr, :analyzer, :queue_changed], measurements, metadata)
  end

  defp dispatch_videos(state) do
    # First, dispatch any manually queued videos (e.g., force_reanalyze)
    {manual_videos, remaining_manual} = Enum.split(state.manual_queue, state.demand)

    dispatched_count = length(manual_videos)
    remaining_demand = state.demand - dispatched_count

    Logger.debug(
      "Dispatching videos - manual: #{length(manual_videos)}, remaining_demand: #{remaining_demand}"
    )

    if length(manual_videos) > 0 do
      Logger.info(
        "Manual videos being dispatched: #{inspect(Enum.map(manual_videos, & &1.path))}"
      )
    end

    # If we still have demand after manual videos, get videos from the database
    database_videos =
      if remaining_demand > 0 do
        videos = Media.get_videos_needing_analysis(remaining_demand)
        Logger.debug("Database videos fetched: #{length(videos)} videos")

        if length(videos) > 0 do
          Logger.debug("Database video paths: #{inspect(Enum.map(videos, & &1.path))}")
          debug_video_states(videos)
        end

        videos
      else
        []
      end

    all_videos = manual_videos ++ database_videos

    case all_videos do
      [] ->
        # No videos available - go to idle if currently running
        if state.status == :running do
          Logger.info("Analyzer going idle - no videos to process")

          # Send to Dashboard V2
          alias Reencodarr.Dashboard.Events
          Events.analyzer_idle()

          new_state = State.update(state, status: :idle)
          # Don't broadcast queue state during idle transition - queue hasn't actually changed
          {:noreply, [], new_state}
        else
          Logger.debug("No videos available for dispatch, keeping demand: #{state.demand}")
          {:noreply, [], state}
        end

      videos ->
        Logger.debug("Broadway producer dispatching #{length(videos)} videos for analysis")
        Logger.debug("All videos being dispatched: #{inspect(Enum.map(videos, & &1.path))}")
        new_demand = state.demand - length(videos)
        new_state = State.update(state, demand: new_demand, manual_queue: remaining_manual)

        # Always broadcast queue state when dispatching videos
        broadcast_queue_state(remaining_manual)

        {:noreply, videos, new_state}
    end
  end

  @doc """
  Debug function to check Broadway pipeline and producer status
  """
  def debug_status do
    broadway_name = Reencodarr.Analyzer.Broadway

    case Process.whereis(broadway_name) do
      nil ->
        IO.puts("❌ Broadway pipeline not found")
        {:error, :broadway_not_found}

      broadway_pid ->
        IO.puts("✅ Broadway pipeline found: #{inspect(broadway_pid)}")
        debug_producer_supervisor(broadway_name)
    end
  end

  defp debug_producer_supervisor(broadway_name) do
    producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

    case Process.whereis(producer_supervisor_name) do
      nil ->
        IO.puts("❌ Producer supervisor not found")
        {:error, :producer_supervisor_not_found}

      producer_supervisor_pid ->
        IO.puts("✅ Producer supervisor found: #{inspect(producer_supervisor_pid)}")
        debug_producer_children(producer_supervisor_pid)
    end
  end

  defp debug_producer_children(producer_supervisor_pid) do
    children = Supervisor.which_children(producer_supervisor_pid)
    IO.puts("Producer supervisor children: #{inspect(children)}")

    case find_actual_producer(children) do
      nil ->
        IO.puts("❌ Producer process not found in supervision tree")
        {:error, :producer_process_not_found}

      producer_pid ->
        IO.puts("✅ Producer process found: #{inspect(producer_pid)}")
        get_producer_state(producer_pid)
    end
  end

  # Helper to get and display producer state
  defp get_producer_state(producer_pid) do
    state = GenStage.call(producer_pid, :get_state, 1000)

    IO.puts(
      "State: demand=#{state.demand}, status=#{state.status}, queue_size=#{length(state.manual_queue)}"
    )

    case state.manual_queue do
      [] ->
        :ok

      videos ->
        IO.puts("Manual queue contents:")
        Enum.each(videos, fn video -> IO.puts("  - #{video.path}") end)
    end

    # Get up to 5 videos from queue or database for batching
    case get_next_videos(state, min(state.demand, 5)) do
      {[], new_state} ->
        Logger.debug("No videos available, resetting processing flag")
        # No videos available, reset processing flag
        {:noreply, [], %{new_state | processing: false}}

      {videos, new_state} ->
        video_count = length(videos)
        Logger.debug("Dispatching #{video_count} videos for analysis")
        # Decrement demand and mark as processing
        final_state =
          State.update(new_state, demand: state.demand - video_count, status: :processing)

        Logger.debug("Final state: status: #{final_state.status}, demand: #{final_state.demand}")

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

  # Debug helper function to check video states
  defp debug_video_states(videos) do
    Enum.each(videos, fn video_info ->
      case Media.get_video_by_path(video_info.path) do
        {:error, :not_found} ->
          Logger.debug("video not found in database", path: video_info.path)

        {:ok, video} ->
          Logger.debug("video state check", path: video_info.path, state: video.state)
      end
    end)
  end

  # Helper function to force dispatch when analyzer is running
  defp force_dispatch_if_running(%State{status: :running, demand: 0} = state) do
    videos = Media.get_videos_needing_analysis(1)

    if length(videos) > 0 do
      Logger.debug(
        "[Analyzer Producer] Force dispatching video to wake up idle Broadway pipeline"
      )

      # Temporarily add demand to force dispatch, then call dispatch_if_ready
      temp_state = State.update(state, demand: 1)
      dispatch_if_ready(temp_state)
    else
      {:noreply, [], state}
    end
  end

  defp force_dispatch_if_running(state) do
    # Already has demand or not running, use normal dispatch
    dispatch_if_ready(state)
  end
end
