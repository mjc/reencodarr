defmodule Reencodarr.CrfSearcher do
  use GenServer

  alias Reencodarr.{Media, AbAv1}
  alias Reencodarr.Distributed.{Coordinator, JobDistributor}
  require Logger

  @check_interval 3000

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    Logger.info("Starting CrfSearcher...")
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def start, do: GenServer.cast(__MODULE__, :start_searching)
  def pause, do: GenServer.cast(__MODULE__, :pause_searching)
  def scanning?, do: GenServer.call(__MODULE__, :scanning?)
  # Returns true if CRF searching is active, false otherwise
  def running? do
    case GenServer.whereis(__MODULE__) do
      nil ->
        false

      pid ->
        GenServer.call(pid, :searching?)
    end
  end

  # GenServer Callbacks
  @impl true
  def init(:ok) do
    Logger.info("Initializing CrfSearcher...")
    monitor_crf_search()
    {:ok, %{searching: false, job_queue: []}}
  end

  @impl true
  def handle_cast(:start_searching, state) do
    Logger.debug("CRF searching started")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :started})
    schedule_check()
    {:noreply, %{state | searching: true}}
  end

  @impl true
  def handle_cast(:pause_searching, state) do
    Logger.debug("CRF searching paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :paused})
    {:noreply, %{state | searching: false}}
  end

  @impl true
  def handle_cast(:crf_search_finished, state) do
    Logger.info("Received notification that CRF search finished.")
    # No immediate get_next_crf_search; periodic check will handle it
    {:noreply, state}
  end
    @impl true
  def handle_cast({:delegate_crf_search, video}, state) do
    Logger.info("Received delegated CRF search for video: #{video.id}")

    # Check if we have the capability to process this job
    local_capabilities = Coordinator.get_local_capabilities()
    has_capability = :crf_search in local_capabilities

    cond do
      not has_capability ->
        Logger.warning("Cannot process delegated CRF search for video #{video.id} - node does not have :crf_search capability")
        {:noreply, state}

      not Media.can_access_database?() ->
        Logger.info("Worker node cannot access database, delegating CRF search execution to server for video #{video.id}")
        Media.execute_crf_search(video)
        {:noreply, state}

      true ->
        # This node has database access and capability, process locally
        crf_search_running = AbAv1.CrfSearch.running?()
        Logger.debug("CrfSearcher state - searching: #{state.searching}, AbAv1.CrfSearch.running?: #{crf_search_running}")

        cond do
          not state.searching ->
            Logger.info("Auto-starting CrfSearcher to process delegated job for video #{video.id}")
            # Auto-start searching and process the job
            Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :started})
            schedule_check()
            if not crf_search_running do
              Logger.info("Processing delegated CRF search for video: #{video.id}")
              AbAv1.crf_search(video)
            end
            {:noreply, %{state | searching: true}}

          crf_search_running ->
            Logger.info("CRF search already running, queueing delegated job for video #{video.id}")
            updated_queue = state.job_queue ++ [video]
            {:noreply, %{state | job_queue: updated_queue}}

          true ->
            Logger.info("Processing delegated CRF search for video: #{video.id}")
            AbAv1.crf_search(video)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_call(:scanning?, _from, %{searching: searching} = state) do
    {:reply, searching, state}
  end

  @impl true
  def handle_call(:searching?, _from, %{searching: searching} = state) do
    {:reply, searching, state}
  end

  @impl true
  def handle_info(:check_next_crf_search, %{searching: true} = state) do
    get_next_crf_search()

    # Process any queued jobs
    updated_state = process_job_queue(state)

    schedule_check()
    {:noreply, updated_state}
  end

  def handle_info(:check_next_crf_search, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warning("AbAv1.CrfSearch process crashed or is not yet started.")
    Process.send_after(self(), :monitor_crf_search, 10_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:monitor_crf_search, state) do
    monitor_crf_search()
    {:noreply, state}
  end

  # Private Helper Functions
  defp monitor_crf_search do
    case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
      nil ->
        Logger.error("CrfSearch process is not running.")
        Process.send_after(self(), :monitor_crf_search, 10_000)

      pid ->
        Process.monitor(pid)
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_next_crf_search, @check_interval)
  end

  defp get_next_crf_search do
    with {:started, pid} when not is_nil(pid) <-
           {:started, GenServer.whereis(Reencodarr.AbAv1.CrfSearch)},
         {:running, false} <- {:running, AbAv1.CrfSearch.running?()} do

      # Calculate optimal batch size based on available nodes
      batch_size = JobDistributor.calculate_optimal_batch_size(:crf_search)

      case Media.get_next_crf_search(batch_size) do
        videos when videos != [] ->
          # Distribute jobs across available capable nodes
          distribute_crf_search_jobs(videos)
        [] ->
          Logger.debug("No videos found without VMAFs")
      end
    else
      {:started, nil} ->
        Logger.warning("CrfSearch process is not started.")

      {:running, true} ->
        Logger.debug("CRF search is already in progress, skipping search for new videos.")
    end
  end

  # Distribute multiple CRF search jobs across capable nodes
  defp distribute_crf_search_jobs(videos) do
    job_processor = &AbAv1.crf_search/1
    job_delegator = fn video, target_node ->
      GenServer.cast({__MODULE__, target_node}, {:delegate_crf_search, video})
    end

    JobDistributor.distribute_jobs(videos, :crf_search, job_processor, job_delegator)
  end

  # Process any queued jobs when the system becomes available
  defp process_job_queue(%{job_queue: []} = state), do: state

  defp process_job_queue(%{job_queue: [video | remaining_jobs]} = state) do
    crf_search_running = AbAv1.CrfSearch.running?()

    if not crf_search_running and state.searching do
      Logger.info("Processing queued CRF search for video: #{video.id}")
      AbAv1.crf_search(video)
      %{state | job_queue: remaining_jobs}
    else
      # Still busy or not searching, keep the queue as is
      state
    end
  end

end
