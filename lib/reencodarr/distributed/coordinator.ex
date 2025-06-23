defmodule Reencodarr.Distributed.Coordinator do
  @moduledoc """
  Simple distributed coordination using libring for consistent hashing.

  This module provides a lightweight wrapper around libring to distribute
  work across connected nodes using consistent hashing.
  """

  use GenServer
  require Logger

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Find the best node for a specific job using consistent hashing.
  """
  def find_node_for_job(job_key, _job_type \\ :any) do
    GenServer.call(__MODULE__, {:find_node, job_key})
  end

  @doc """
  Get all connected nodes that can handle work.
  """
  def get_nodes_for_capability(_capability) do
    GenServer.call(__MODULE__, :get_nodes)
  end

  @doc """
  Check if we're running in distributed mode.
  """
  def distributed_mode? do
    length(Node.list()) > 0
  end

  @doc """
  Get cluster status and ring information.
  """
  def cluster_info do
    GenServer.call(__MODULE__, :cluster_info)
  end

  @doc """
  Get current local capabilities for this node.
  """
  def get_local_capabilities do
    get_local_capabilities_internal()
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Monitor node connections
    :net_kernel.monitor_nodes(true)

    # Create ring with current node
    ring = HashRing.new() |> HashRing.add_node(Node.self())

    state = %{
      ring: ring,
      local_capabilities: get_local_capabilities_internal()
    }

    Logger.info("Distributed coordinator initialized on #{Node.self()}")
    {:ok, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node #{node} joined cluster")
    new_ring = HashRing.add_node(state.ring, node)
    {:noreply, %{state | ring: new_ring}}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node #{node} left cluster")
    new_ring = HashRing.remove_node(state.ring, node)
    {:noreply, %{state | ring: new_ring}}
  end

  @impl true
  def handle_call({:find_node, job_key}, _from, state) do
    result = case HashRing.key_to_node(state.ring, to_string(job_key)) do
      {:ok, node} -> {:ok, node}
      {:error, {:invalid_ring, :no_nodes}} -> {:error, :no_nodes}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_nodes, _from, state) do
    nodes = HashRing.nodes(state.ring)
    {:reply, nodes, state}
  end

  @impl true
  def handle_call(:cluster_info, _from, state) do
    all_nodes = HashRing.nodes(state.ring)

    # Create node_capabilities map for backwards compatibility with UI
    node_capabilities = Map.new(all_nodes, fn node ->
      {node, state.local_capabilities}
    end)

    info = %{
      local_node: Node.self(),
      cluster_nodes: all_nodes,
      all_connected_nodes: [Node.self() | Node.list()],
      ring_size: length(all_nodes),
      node_capabilities: node_capabilities,
      local_capabilities: state.local_capabilities,
      health_info: %{}
    }

    {:reply, info, state}
  end

  # Private functions

  defp get_local_capabilities_internal do
    # Can be configured via environment or config
    Application.get_env(:reencodarr, :node_capabilities, [:crf_search, :encode])
  end
end
