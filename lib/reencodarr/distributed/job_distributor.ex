defmodule Reencodarr.Distributed.JobDistributor do
  @moduledoc """
  Handles intelligent job distribution across capable nodes in a distributed cluster.

  Features:
  - Dynamic batch sizing based on available nodes
  - Busy node filtering to prevent "already in progress" errors
  - Round-robin job assignment for even load distribution
  - Job queueing when nodes are temporarily busy

  Jobs are only sent to nodes that have the required capability. Worker nodes
  handle database operations via RPC if they don't have direct database access,
  so no jobs are ever "punted back" to the server.
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
    config = job_config(job_type)

    if node == Node.self() do
      # For the local node, check directly
      config.runner_module.running?()
    else
      # For remote nodes, call the appropriate GenServer to check if they're busy
      try do
        GenServer.call({config.genserver_module, node}, config.status_call, 1000)
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

  # Private Functions

  # Job type configuration - defines the differences between job types
  defp job_config(:crf_search) do
    %{
      runner_module: AbAv1.CrfSearch,
      genserver_module: Reencodarr.CrfSearcher,
      status_call: :searching?,
      id_extractor: fn job -> job.id end
    }
  end

  defp job_config(:encode) do
    %{
      runner_module: AbAv1.Encode,
      genserver_module: Reencodarr.Encoder,
      status_call: :encoding?,
      id_extractor: fn job -> job.video.id end
    }
  end

  defp get_available_nodes_for_capability(capability) do
    # Get nodes that have the capability and filter out busy ones
    capable_nodes = Coordinator.get_nodes_for_capability(capability)
    filter_available_nodes(capable_nodes, capability)
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
      config = job_config(capability)
      video_id = config.id_extractor.(job)

      Logger.debug("Next video for #{capability}: #{video_id}")
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
    config = job_config(job_type)

    Logger.info("Distributing #{job_count} #{job_type} jobs across #{node_count} available nodes")

    # Use simple round-robin to ensure even distribution
    jobs
    |> Enum.with_index()
    |> Enum.each(fn {job, index} ->
      # Round-robin assignment: use modulo to cycle through nodes
      target_node = Enum.at(available_nodes, rem(index, node_count))
      video_id = config.id_extractor.(job)

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
