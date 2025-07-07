defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Broadway producer for CRF search operations.

  This producer dispatches videos for CRF search only when the CRF search
  GenServer is available, preventing duplicate work and resource waste.
  """

  use GenStage
  require Logger
  alias Reencodarr.Media

  @broadway_name Reencodarr.CrfSearcher.Broadway

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API for external control
  def pause, do: send_to_producer(:pause)
  def resume, do: send_to_producer(:resume)
  def dispatch_available, do: send_to_producer(:dispatch_available)
  def add_video(video), do: send_to_producer({:add_video, video})

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

    {:producer,
     %{
       demand: 0,
       paused: true,
       queue: :queue.new(),
       # Track if we're currently processing a video
       processing: false
     }}
  end

  @impl GenStage
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_call(:running?, _from, state) do
    {:reply, not state.paused, [], state}
  end

  @impl GenStage
  def handle_cast(:pause, state) do
    Logger.info("CrfSearcher paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :paused})
    {:noreply, [], %{state | paused: true}}
  end

  @impl GenStage
  def handle_cast(:resume, state) do
    Logger.info("CrfSearcher resumed")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :started})
    new_state = %{state | paused: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast({:add_video, video}, state) do
    new_queue = :queue.in(video, state.queue)
    new_state = %{state | queue: new_queue}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_cast(:dispatch_available, state) do
    # CRF search completed, mark as not processing and try to dispatch next
    new_state = %{state | processing: false}
    dispatch_if_ready(new_state)
  end

  @impl GenStage
  def handle_info({:video_upserted, _video}, state) do
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
    if should_dispatch?(state) and state.demand > 0 do
      dispatch_videos(state)
    else
      {:noreply, [], state}
    end
  end

  defp should_dispatch?(state) do
    not state.paused and not state.processing and crf_search_available?()
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
          Logger.info("Dispatching video #{video.id} for CRF search")
          # Mark as processing and decrement demand
          updated_state = %{new_state | demand: state.demand - 1, processing: true}
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
        case Media.get_next_crf_search(1) do
          [video | _] -> {video, state}
          [] -> {nil, state}
        end
    end
  end
end
