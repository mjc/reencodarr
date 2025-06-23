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
  Get all connected nodes that can handle a specific capability.
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

  @doc """
  Update capabilities for a specific node.
  """
  def update_node_capabilities(node, capabilities) when is_list(capabilities) do
    GenServer.call(__MODULE__, {:update_node_capabilities, node, capabilities})
  end

  @doc """
  Add a capability to a specific node.
  """
  def add_node_capability(node, capability) when is_atom(capability) do
    GenServer.call(__MODULE__, {:add_node_capability, node, capability})
  end

  @doc """
  Remove a capability from a specific node.
  """
  def remove_node_capability(node, capability) when is_atom(capability) do
    GenServer.call(__MODULE__, {:remove_node_capability, node, capability})
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
      node_health: %{Node.self() => %{status: :healthy, last_seen: DateTime.utc_now()}},
      node_capabilities: %{Node.self() => get_local_capabilities_internal()}
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

    # Try to get capabilities from the new node, fallback to default
    node_capabilities = try do
      :rpc.call(node, Application, :get_env, [:reencodarr, :node_capabilities, [:crf_search, :encode]], 1000)
    catch
      _, _ -> [:crf_search, :encode]  # Default capabilities
    end

    new_capabilities = Map.put(state.node_capabilities, node, node_capabilities)

    # Broadcast cluster change to update dashboard
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "cluster",
      {:cluster_change, :node_added, node, node_capabilities}
    )

    {:noreply, %{state | ring: new_ring, node_health: new_health, node_capabilities: new_capabilities}}
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
      {:error, reason} -> {:error, reason}
      node when is_atom(node) -> {:ok, node}  # HashRing might return node directly
      error -> {:error, error}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_nodes, _from, state) do
    nodes = HashRing.nodes(state.ring)
    {:reply, nodes, state}
  end

  @impl true
  def handle_call({:get_nodes_for_capability, capability}, _from, state) do
    # Filter nodes that have the requested capability
    capable_nodes = state.node_capabilities
                   |> Enum.filter(fn {node, capabilities} ->
                        # Only include nodes that are in the ring and have the capability
                        node in HashRing.nodes(state.ring) and capability in capabilities
                      end)
                   |> Enum.map(fn {node, _capabilities} -> node end)

    {:reply, capable_nodes, state}
  end

  @impl true
  def handle_call(:cluster_info, _from, state) do
    all_nodes = HashRing.nodes(state.ring)

    # Use tracked node capabilities instead of assuming all nodes have the same capabilities
    node_capabilities = state.node_capabilities

    # Only include health info for nodes that are currently connected
    active_health = state.node_health
                   |> Enum.filter(fn {node, health} ->
                        health.status == :healthy and node in all_nodes
                      end)
                   |> Enum.into(%{})

    # Calculate ring sizes for each capability
    ring_sizes = %{
      crf_search: length(get_nodes_for_capability_internal(:crf_search, state)),
      encode: length(get_nodes_for_capability_internal(:encode, state)),
      any: length(all_nodes)
    }

    info = %{
      local_node: Node.self(),
      cluster_nodes: all_nodes,
      all_connected_nodes: [Node.self() | Node.list()],
      ring_size: length(all_nodes),
      ring_sizes: ring_sizes,
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
  def handle_call({:update_node_capabilities, node, capabilities}, _from, state) do
    # Only allow local node to update its own capabilities
    if node == Node.self() do
      # Update application environment
      Application.put_env(:reencodarr, :node_capabilities, capabilities)

      new_capabilities = Map.put(state.node_capabilities, node, capabilities)
      new_state = %{state |
        local_capabilities: capabilities,
        node_capabilities: new_capabilities
      }

      # Broadcast capability change
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "cluster",
        {:cluster_change, :capabilities_updated, node, capabilities}
      )

      {:reply, :ok, new_state}
    else
      # For remote nodes, make an RPC call
      case :rpc.call(node, __MODULE__, :update_node_capabilities, [node, capabilities]) do
        :ok -> {:reply, :ok, state}
        error -> {:reply, {:error, error}, state}
      end
    end
  end

  @impl true
  def handle_call({:add_node_capability, node, capability}, _from, state) do
    current_capabilities = Map.get(state.node_capabilities, node, [])
    new_capabilities = [capability | current_capabilities] |> Enum.uniq()
    handle_call({:update_node_capabilities, node, new_capabilities}, nil, state)
  end

  @impl true
  def handle_call({:remove_node_capability, node, capability}, _from, state) do
    current_capabilities = Map.get(state.node_capabilities, node, [])
    new_capabilities = List.delete(current_capabilities, capability)
    handle_call({:update_node_capabilities, node, new_capabilities}, nil, state)
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

  # Helper function to get nodes for capability without GenServer call (for internal use)
  defp get_nodes_for_capability_internal(capability, state) do
    state.node_capabilities
    |> Enum.filter(fn {node, capabilities} ->
         # Only include nodes that are in the ring and have the capability
         node in HashRing.nodes(state.ring) and capability in capabilities
       end)
    |> Enum.map(fn {node, _capabilities} -> node end)
  end
end
