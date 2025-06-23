defmodule Reencodarr.Distributed.HealthMonitor do
  @moduledoc """
  Health monitoring for distributed nodes.

  This module periodically checks the health of cluster nodes,
  collects system metrics, and handles node failure detection
  and recovery.
  """

  use GenServer
  require Logger

  @health_check_interval :timer.seconds(30)
  @node_timeout :timer.seconds(10)

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
    schedule_health_check()

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
    new_state = perform_health_check(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_check(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  # Private functions

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp perform_health_check(state) do
    Logger.debug("Performing cluster health check")

    # Get all nodes (including self)
    all_nodes = [Node.self() | Node.list()]

    # Check health of each node
    health_results =
      all_nodes
      |> Enum.map(&check_node_health/1)
      |> Enum.into(%{})

    # Update state
    %{state |
      node_health: health_results,
      last_check: DateTime.utc_now()
    }
  end

  defp check_node_health(node) do
    start_time = System.monotonic_time(:millisecond)

    health_info = try do
      case Node.ping(node) do
        :pong ->
          # Node is reachable, get detailed metrics
          metrics = get_node_metrics(node)
          response_time = System.monotonic_time(:millisecond) - start_time

          %{
            status: :healthy,
            response_time: response_time,
            last_seen: DateTime.utc_now(),
            metrics: metrics
          }

        :pang ->
          %{
            status: :unreachable,
            response_time: nil,
            last_seen: nil,
            metrics: %{}
          }
      end
    rescue
      error ->
        Logger.warning("Health check failed for node #{node}: #{inspect(error)}")
        %{
          status: :error,
          response_time: nil,
          last_seen: nil,
          metrics: %{},
          error: inspect(error)
        }
    end

    {node, health_info}
  end

  defp get_node_metrics(node) do
    try do
      case :rpc.call(node, __MODULE__, :collect_local_metrics, [], @node_timeout) do
        {:ok, metrics} -> metrics
        {:error, reason} ->
          Logger.warning("Failed to collect metrics from #{node}: #{inspect(reason)}")
          %{}
        {:badrpc, reason} ->
          Logger.warning("RPC failed for metrics collection from #{node}: #{inspect(reason)}")
          %{}
      end
    catch
      :exit, reason ->
        Logger.warning("Metrics collection timeout for #{node}: #{inspect(reason)}")
        %{}
    end
  end

  @doc """
  Collect local system metrics for health reporting.
  This function is called via RPC from other nodes.
  """
  def collect_local_metrics do
    try do
      # Get system info
      {memory_total, memory_used, _} = :memsup.get_memory_data()
      cpu_utilization = :cpu_sup.util([:detailed])

      # Get process counts
      process_count = length(Process.list())

      # Get BEAM VM info
      vm_info = %{
        schedulers: :erlang.system_info(:schedulers),
        scheduler_utilization: :scheduler.utilization(1000),
        memory_total: :erlang.memory(:total),
        memory_processes: :erlang.memory(:processes),
        memory_system: :erlang.memory(:system)
      }

      # Get application-specific info
      app_info = get_app_metrics()

      metrics = %{
        system: %{
          memory_total_mb: div(memory_total, 1024 * 1024),
          memory_used_mb: div(memory_used, 1024 * 1024),
          memory_usage_percent: div(memory_used * 100, memory_total),
          cpu_utilization: cpu_utilization,
          process_count: process_count,
          uptime_seconds: div(:erlang.statistics(:wall_clock) |> elem(0), 1000)
        },
        vm: vm_info,
        application: app_info,
        timestamp: DateTime.utc_now()
      }

      {:ok, metrics}
    rescue
      error ->
        Logger.error("Failed to collect local metrics: #{inspect(error)}")
        {:error, inspect(error)}
    end
  end

  defp get_app_metrics do
    try do
      # Check if key processes are running
      coordinator_running = Process.whereis(Reencodarr.Distributed.Coordinator) != nil
      crf_searcher_running = Process.whereis(Reencodarr.CrfSearcher) != nil
      encoder_running = Process.whereis(Reencodarr.Encoder) != nil

      # Get capabilities from coordinator if available
      capabilities = try do
        if coordinator_running do
          GenServer.call(Reencodarr.Distributed.Coordinator, :get_local_capabilities, 1000)
        else
          []
        end
      catch
        :exit, _ -> []
      end

      %{
        coordinator_running: coordinator_running,
        crf_searcher_running: crf_searcher_running,
        encoder_running: encoder_running,
        capabilities: capabilities,
        node_type: get_node_type()
      }
    rescue
      _ -> %{}
    end
  end

  defp get_node_type do
    # Determine if this is a server or worker node
    web_endpoint_running = Process.whereis(ReencodarrWeb.Endpoint) != nil

    if web_endpoint_running do
      :server
    else
      :worker
    end
  end
end
