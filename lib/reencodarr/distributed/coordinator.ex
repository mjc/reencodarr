defmodule Reencodarr.Distributed.Coordinator do
  @moduledoc """
  Distributed coordination using libring for consistent hashing.

  This module manages the cluster of worker nodes and distributes
  work using consistent hashing to ensure even distribution and
  node affinity for better performance.
  """

  use GenServer
  require Logger

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register current node capabilities with the cluster.
  """
  def register_node(capabilities \\ [:crf_search, :encode]) do
    GenServer.call(__MODULE__, {:register_node, Node.self(), capabilities})
  end

  @doc """
  Find the best node for a specific job using consistent hashing.
  """
  def find_node_for_job(job_key, job_type \\ :any) do
    GenServer.call(__MODULE__, {:find_node, job_key, job_type})
  end

  @doc """
  Get all nodes that can handle a specific job type.
  """
  def get_nodes_for_capability(capability) do
    GenServer.call(__MODULE__, {:get_nodes_for_capability, capability})
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

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Monitor node connections
    :net_kernel.monitor_nodes(true)

    # Initialize rings for different capabilities
    state = %{
      rings: %{
        crf_search: HashRing.new(),
        encode: HashRing.new(),
        any: HashRing.new()
      },
      node_capabilities: %{},
      local_capabilities: get_local_capabilities()
    }

    # Register this node
    send(self(), {:register_self})

    Logger.info("Distributed coordinator initialized on #{Node.self()}")
    {:ok, state}
  end

  @impl true
  def handle_info({:register_self}, state) do
    # Register this node with its capabilities
    new_state = register_node_internal(Node.self(), state.local_capabilities, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node #{node} joined cluster")

    # Node will register itself when ready
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node #{node} left cluster")

    # Remove node from all rings
    new_rings =
      state.rings
      |> Enum.map(fn {capability, ring} ->
        {capability, HashRing.remove_node(ring, node)}
      end)
      |> Enum.into(%{})

    # Remove from capabilities
    new_node_capabilities = Map.delete(state.node_capabilities, node)

    new_state = %{
      state |
      rings: new_rings,
      node_capabilities: new_node_capabilities
    }

    # Broadcast cluster change
    broadcast_cluster_change(:node_removed, node)

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:register_node, node, capabilities}, _from, state) do
    new_state = register_node_internal(node, capabilities, state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:find_node, job_key, job_type}, _from, state) do
    ring = case Map.get(state.rings, job_type) do
      nil -> state.rings.any  # Fallback to any ring
      ring -> ring
    end

    result = case HashRing.key_to_node(ring, to_string(job_key)) do
      {:ok, node} -> {:ok, node}
      {:error, {:invalid_ring, :no_nodes}} -> {:error, :no_nodes}
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_node_for_job, job_id, capability}, _from, state) do
    # ...existing handle_call code...
  end

  @impl true
  def handle_call({:get_nodes_for_capability, capability}, _from, state) do
    nodes = case Map.get(state.rings, capability) do
      nil -> []
      ring -> HashRing.nodes(ring)
    end

    {:reply, nodes, state}
  end

  @impl true
  def handle_call(:cluster_info, _from, state) do
    info = %{
      local_node: Node.self(),
      cluster_nodes: [Node.self() | Node.list()],
      ring_sizes: state.rings |> Enum.map(fn {k, ring} -> {k, length(HashRing.nodes(ring))} end) |> Enum.into(%{}),
      node_capabilities: state.node_capabilities,
      local_capabilities: state.local_capabilities
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_cluster_status, _from, state) do
    cluster_status = %{
      nodes: Map.keys(state.node_capabilities),
      node_capabilities: state.node_capabilities,
      rings_summary: Map.new(state.rings, fn {cap, ring} ->
        {cap, HashRing.nodes(ring)}
      end)
    }
    {:reply, cluster_status, state}
  end

  # Private functions

  defp register_node_internal(node, capabilities, state) do
    Logger.info("Registering node #{node} with capabilities: #{inspect(capabilities)}")

    # Add node to appropriate rings
    new_rings =
      capabilities
      |> Enum.reduce(state.rings, fn capability, rings ->
        Map.update!(rings, capability, &HashRing.add_node(&1, node))
      end)
      |> Map.update!(:any, &HashRing.add_node(&1, node))

    # Update node capabilities
    new_node_capabilities = Map.put(state.node_capabilities, node, capabilities)

    # Broadcast cluster change
    broadcast_cluster_change(:node_added, node, capabilities)

    %{
      state |
      rings: new_rings,
      node_capabilities: new_node_capabilities
    }
  end

  defp broadcast_cluster_change(event, node, capabilities \\ []) do
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "cluster",
      {:cluster_change, event, node, capabilities}
    )
  end

  defp get_local_capabilities do
    # Can be configured via environment or config
    Application.get_env(:reencodarr, :node_capabilities, [:crf_search, :encode])
  end
end
