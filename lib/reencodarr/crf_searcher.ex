defmodule Reencodarr.CrfSearcher do
  use GenServer

  alias Reencodarr.{Media, AbAv1}
  alias Reencodarr.Distributed.Coordinator
  require Logger

  @check_interval 5000

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
    {:ok, %{searching: false}}
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

    # Only process if we're currently searching and CRF search is available
    if state.searching and not AbAv1.CrfSearch.running?() do
      AbAv1.crf_search(video)
    else
      Logger.debug("Cannot process delegated CRF search - either not searching or CRF search busy")
    end

    {:noreply, state}
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
    schedule_check()
    {:noreply, state}
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
         {:running, false} <- {:running, AbAv1.CrfSearch.running?()},
         [video | _] <- Media.get_next_crf_search(1) do
           
      # Check if we should handle this job or delegate to another node
      case should_handle_job_locally?(video) do
        true ->
          Logger.info("Calling AbAv1.crf_search for video: #{video.id}")
          AbAv1.crf_search(video)
          
        false ->
          delegate_crf_search(video)
      end
    else
      {:started, nil} ->
        Logger.warning("CrfSearch process is not started.")

      {:running, true} ->
        Logger.debug("CRF search is already in progress, skipping search for new videos.")

      [] ->
        Logger.debug("No videos found without VMAFs")
    end
  end
  
  # Determine if this node should handle the job based on consistent hashing
  defp should_handle_job_locally?(video) do
    if Coordinator.distributed_mode?() do
      case Coordinator.find_node_for_job(video.id, :crf_search) do
        {:ok, node} -> node == Node.self()
        {:error, :no_nodes} -> true  # Fallback to local processing
      end
    else
      true  # Always handle locally in non-distributed mode
    end
  end
  
  # Delegate CRF search to the appropriate node
  defp delegate_crf_search(video) do
    case Coordinator.find_node_for_job(video.id, :crf_search) do
      {:ok, target_node} ->
        Logger.info("Delegating CRF search for video #{video.id} to node #{target_node}")
        
        try do
          GenServer.cast({__MODULE__, target_node}, {:delegate_crf_search, video})
        catch
          :exit, reason ->
            Logger.warning("Failed to delegate to #{target_node}: #{inspect(reason)}, handling locally")
            AbAv1.crf_search(video)
        end
        
      {:error, :no_nodes} ->
        Logger.info("No distributed nodes available, handling CRF search locally")
        AbAv1.crf_search(video)
    end
  end
end
