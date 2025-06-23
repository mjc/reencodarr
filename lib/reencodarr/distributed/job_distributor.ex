defmodule Reencodarr.Distributed.JobDistributor do
  @moduledoc """
  Handles intelligent job distribution across capable nodes in a distributed cluster.

  Features:
  - Dynamic batch sizing based on available nodes
  - Busy node filtering to prevent "already in progress" errors
  - Round-robin job assignment for even load distribution
  - Job queueing when nodes are temporarily busy
  """

  require Logger
  alias Reencodarr.Distributed.Coordinator
  alias Reencodarr.AbAv1

  @doc """
  Distributes jobs across available capable nodes for a given capability.

  ## Parameters
  - `jobs`: List of jobs to distribute (videos for CRF search, vmafs for encoding)
  - `capability`: The required capability (:crf_search or :encode)
  - `job_processor`: Function to process jobs locally when target is current node
  - `job_delegator`: Function to delegate jobs to remote nodes

  ## Examples
      distribute_jobs(videos, :crf_search, &AbAv1.crf_search/1, fn video, node ->
        GenServer.cast({Reencodarr.CrfSearcher, node}, {:delegate_crf_search, video})
      end)
  """
  def distribute_jobs(jobs, capability, job_processor, job_delegator) when is_list(jobs) do
    if Coordinator.distributed_mode?() do
      case get_available_nodes_for_capability(capability) do
        [] ->
          Logger.warning("No available nodes with #{capability} capability")
        available_nodes ->
          distribute_jobs_to_nodes(jobs, available_nodes, capability, job_processor, job_delegator)
      end
    else
      # In non-distributed mode, process one job locally if we have capability
      process_local_job_if_capable(jobs, capability, job_processor)
    end
  end

  @doc """
  Calculates the optimal batch size for fetching jobs based on available nodes.

  Returns the number of jobs that should be fetched from the database to
  efficiently distribute across available nodes without overwhelming them.
  """
  def calculate_optimal_batch_size(capability) do
    if Coordinator.distributed_mode?() do
      available_nodes = get_available_nodes_for_capability(capability)
      calculate_batch_size_for_nodes(available_nodes)
    else
      # In non-distributed mode, process one job at a time
      local_capabilities = Coordinator.get_local_capabilities()
      if capability in local_capabilities, do: 1, else: 0
    end
  end

  @doc """
  Checks if a node is currently busy with a job of the given type.
  """
  def is_node_busy?(node, job_type) do
    if node == Node.self() do
      # For the local node, check directly
      case job_type do
        :crf_search -> AbAv1.CrfSearch.running?()
        :encode -> AbAv1.Encode.running?()
      end
    else
      # For remote nodes, call the appropriate GenServer to check if they're busy
      try do
        case job_type do
          :crf_search ->
            GenServer.call({Reencodarr.CrfSearcher, node}, :searching?, 1000)
          :encode ->
            GenServer.call({Reencodarr.Encoder, node}, :encoding?, 1000)
        end
      catch
        :exit, _reason ->
          # If we can't reach the node, assume it's not busy (it might be down)
          false
      end
    end
  end

  @doc """
  Filters out busy nodes from the capable nodes list.
  """
  def filter_available_nodes(capable_nodes, job_type) do
    Enum.reject(capable_nodes, fn node ->
      is_node_busy?(node, job_type)
    end)
  end

  @doc """
  Checks if a node can handle database operations either directly or via RPC.
  """
  def can_node_handle_database_operations?(node) do
    if node == Node.self() do
      # For the local node, check directly
      can_access_database_locally?() || can_reach_server_nodes?()
    else
      # For remote nodes, check via RPC
      try do
        case :rpc.call(node, __MODULE__, :can_handle_database_operations_locally, [], 2000) do
          true -> true
          false -> false
          {:badrpc, _} -> false
        end
      catch
        :exit, _reason -> false
      end
    end
  end

  @doc """
  Local check for database operations capability.
  """
  def can_handle_database_operations_locally do
    can_access_database_locally?() || can_reach_server_nodes?()
  end

  # Private Functions

  defp can_access_database_locally? do
    try do
      Ecto.Adapters.SQL.query(Reencodarr.Repo, "SELECT 1", [])
      true
    rescue
      _ -> false
    end
  end

  defp can_reach_server_nodes? do
    case get_server_nodes() do
      [] -> false
      [_server | _] -> true
    end
  end

  defp get_server_nodes do
    all_nodes = [Node.self() | Node.list()]

    # Find nodes that have web server running (indicates server nodes with DB access)
    all_nodes
    |> Enum.filter(fn node ->
      try do
        case :rpc.call(node, Process, :whereis, [ReencodarrWeb.Endpoint], 2_000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      catch
        _, _ -> false
      end
    end)
  end

  defp get_available_nodes_for_capability(capability) do
    capable_nodes = Coordinator.get_nodes_for_capability(capability)

    # Filter by capability and database handling ability
    db_capable_nodes = Enum.filter(capable_nodes, fn node ->
      can_node_handle_database_operations?(node)
    end)

    # Then filter by busy status
    filter_available_nodes(db_capable_nodes, capability)
  end

  defp calculate_batch_size_for_nodes(available_nodes) do
    node_count = length(available_nodes)

    cond do
      node_count == 0 -> 0  # No available nodes
      node_count == 1 -> 1  # Only one node, process one job at a time
      node_count <= 5 -> node_count  # One job per node for small clusters
      true -> 5  # Cap at 5 jobs for larger clusters
    end
  end

  defp process_local_job_if_capable(jobs, capability, job_processor) do
    local_capabilities = Coordinator.get_local_capabilities()
    has_capability = capability in local_capabilities

    if has_capability and jobs != [] do
      [job | _] = jobs

      case capability do
        :crf_search ->
          Logger.debug("Next video for CRF search: #{job.id}")
        :encode ->
          Logger.debug("Next video to re-encode: #{job.video.path}")
      end

      job_processor.(job)
    else
      if not has_capability do
        Logger.warning("Local node does not have #{capability} capability, skipping jobs")
      end
    end
  end

  defp distribute_jobs_to_nodes(jobs, available_nodes, job_type, job_processor, job_delegator) do
    job_count = length(jobs)
    node_count = length(available_nodes)

    Logger.info("Distributing #{job_count} #{job_type} jobs across #{node_count} available nodes")

    # Use simple round-robin to ensure even distribution
    jobs
    |> Enum.with_index()
    |> Enum.each(fn {job, index} ->
      # Round-robin assignment: use modulo to cycle through nodes
      target_node = Enum.at(available_nodes, rem(index, node_count))

      video_id = case job_type do
        :encode -> job.video.id
        :crf_search -> job.id
      end

      if target_node == Node.self() do
        Logger.info("Processing #{job_type} locally for video: #{video_id}")
        job_processor.(job)
      else
        Logger.info("Delegating #{job_type} for video #{video_id} to node #{target_node}")

        try do
          job_delegator.(job, target_node)
        catch
          :exit, reason ->
            Logger.warning("Failed to delegate #{job_type} to #{target_node}: #{inspect(reason)}")
        end
      end

      # Small delay between delegations to avoid overwhelming nodes
      if index < job_count - 1 do
        Process.sleep(50)
      end
    end)
  end
end
