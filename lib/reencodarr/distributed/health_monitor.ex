defmodule Reencodarr.Distributed.HealthMonitor do
  @moduledoc """
  Health monitoring for distributed nodes.

  This module periodically checks the health of cluster nodes,
  collects system metrics, and handles node failure detection
  and recovery.
  """

  use GenServer
  require Logger

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get health status for all cluster nodes.
  """
  def get_cluster_health do
    GenServer.call(__MODULE__, :get_cluster_health)
  end

  @doc """
  Get detailed health metrics for a specific node.
  """
  def get_node_health(node) do
    GenServer.call(__MODULE__, {:get_node_health, node})
  end

  @doc """
  Manually trigger a health check for all nodes.
  """
  def trigger_health_check do
    GenServer.cast(__MODULE__, :trigger_health_check)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Disable periodic health checks to avoid RPC timeouts
    # schedule_health_check()

    state = %{
      node_health: %{},
      last_check: DateTime.utc_now()
    }

    Logger.info("Health monitor started on #{Node.self()}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_cluster_health, _from, state) do
    {:reply, state.node_health, state}
  end

  @impl true
  def handle_call({:get_node_health, node}, _from, state) do
    health = Map.get(state.node_health, node, %{status: :unknown})
    {:reply, health, state}
  end

  @impl true
  def handle_cast(:trigger_health_check, state) do
    # Disabled health checks to avoid RPC timeouts
    # new_state = perform_health_check(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Disabled health checks to avoid RPC timeouts
    # new_state = perform_health_check(state)
    # schedule_health_check()
    {:noreply, state}
  end

  # Private functions - Health checks disabled to avoid RPC timeouts
  # All health monitoring functions have been removed since we moved
  # health tracking to the coordinator using node up/down events
end
