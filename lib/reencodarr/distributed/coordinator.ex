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

  @doc """
  Get health status for the cluster.
  """
  def get_cluster_health do
    GenServer.call(__MODULE__, :get_cluster_health)
  end

  @doc """
  Send a heartbeat to update this node's health status.
  """
  def heartbeat do
    GenServer.cast(__MODULE__, :heartbeat)
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
      local_capabilities: get_local_capabilities_internal(),
      node_health: %{Node.self() => %{status: :healthy, last_seen: DateTime.utc_now()}}
    }

    # Schedule periodic heartbeat
    schedule_heartbeat()

    Logger.info("Distributed coordinator initialized on #{Node.self()}")
    {:ok, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node #{node} joined cluster")
    new_ring = HashRing.add_node(state.ring, node)

    # Mark node as healthy when it connects
    new_health = Map.put(state.node_health, node, %{
      status: :healthy,
      last_seen: DateTime.utc_now()
    })

    # Broadcast cluster change to update dashboard
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "cluster",
      {:cluster_change, :node_added, node, state.local_capabilities}
    )

    {:noreply, %{state | ring: new_ring, node_health: new_health}}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node #{node} left cluster")
    new_ring = HashRing.remove_node(state.ring, node)

    # Mark node as disconnected when it leaves
    new_health = Map.put(state.node_health, node, %{
      status: :disconnected,
      last_seen: DateTime.utc_now()
    })

    # Broadcast cluster change to update dashboard
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "cluster",
      {:cluster_change, :node_removed, node, state.local_capabilities}
    )

    {:noreply, %{state | ring: new_ring, node_health: new_health}}
  end

  @impl true
  def handle_info(:heartbeat_timer, state) do
    # Update our own heartbeat and schedule next one
    new_health = Map.put(state.node_health, Node.self(), %{
      status: :healthy,
      last_seen: DateTime.utc_now()
    })
    schedule_heartbeat()
    {:noreply, %{state | node_health: new_health}}
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

    # Only include health info for nodes that are currently connected
    active_health = state.node_health
                   |> Enum.filter(fn {node, health} ->
                        health.status == :healthy and node in all_nodes
                      end)
                   |> Enum.into(%{})

    info = %{
      local_node: Node.self(),
      cluster_nodes: all_nodes,
      all_connected_nodes: [Node.self() | Node.list()],
      ring_size: length(all_nodes),
      node_capabilities: node_capabilities,
      local_capabilities: state.local_capabilities,
      health_info: active_health
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_cluster_health, _from, state) do
    {:reply, state.node_health, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    # Update our own health status
    new_health = Map.put(state.node_health, Node.self(), %{
      status: :healthy,
      last_seen: DateTime.utc_now()
    })
    {:noreply, %{state | node_health: new_health}}
  end

  # Private functions

  defp get_local_capabilities_internal do
    # Can be configured via environment or config
    Application.get_env(:reencodarr, :node_capabilities, [:crf_search, :encode])
  end

  defp schedule_heartbeat do
    # Send heartbeat every 30 seconds
    Process.send_after(self(), :heartbeat_timer, :timer.seconds(30))
  end
end
