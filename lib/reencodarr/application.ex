defmodule Reencodarr.Application do
  @moduledoc """
  Main OTP Application for Reencodarr.
  
  Builds a supervision tree based on node configuration:
  - Server nodes: Full infrastructure + web interface
  - Worker nodes: Infrastructure for distributed work processing
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = build_supervision_tree()
    
    Logger.info("Starting Reencodarr application", 
      node: Node.self(),
      mode: node_mode(),
      capabilities: node_capabilities()
    )

    Supervisor.start_link(children, strategy: :one_for_one, name: Reencodarr.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ReencodarrWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Build supervision tree based on node configuration
  defp build_supervision_tree do
    base_children() ++
    cluster_children() ++
    server_children() ++
    web_children()
  end

  # Core infrastructure needed by all nodes
  defp base_children do
    [
      # Telemetry and metrics
      ReencodarrWeb.Telemetry,
      # PubSub for inter-process communication  
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      # HTTP client
      {Finch, name: Reencodarr.Finch}
    ]
  end

  # Cluster/distributed infrastructure
  defp cluster_children do
    [
      # DNS cluster for service discovery
      {DNSCluster, query: Application.get_env(:reencodarr, :dns_cluster_query) || :ignore},
      # Node clustering
      {Cluster.Supervisor, [cluster_topology(), [name: Reencodarr.ClusterSupervisor]]},
      # Distributed coordination
      Reencodarr.Distributed.Coordinator,
      # Health monitoring
      Reencodarr.Distributed.HealthMonitor,
      # Worker processes based on capabilities
      worker_supervisor()
    ]
  end

  # Server-only processes (business logic, database, etc.)
  defp server_children do
    if server_node?() do
      [
        # Database
        Reencodarr.Repo,
        # Task supervisor for server coordination
        {Task.Supervisor, name: Reencodarr.TaskSupervisor},
        # Business logic processes
        Reencodarr.Statistics,
        Reencodarr.ManualScanner,
        Reencodarr.Analyzer,
        Reencodarr.Sync
      ]
    else
      []
    end
  end

  # Web interface (only on nodes with web enabled)
  defp web_children do
    if web_enabled?() do
      [ReencodarrWeb.Endpoint]
    else
      []
    end
  end

  # Worker supervisor with capability-based children
  defp worker_supervisor do
    worker_children = [Reencodarr.AbAv1] ++ capability_workers()
    
    %{
      id: Reencodarr.WorkerSupervisor,
      start: {Supervisor, :start_link, [worker_children, [strategy: :one_for_one, name: Reencodarr.WorkerSupervisor]]},
      type: :supervisor
    }
  end

  # Workers based on node capabilities
  defp capability_workers do
    node_capabilities()
    |> Enum.flat_map(fn
      :crf_search -> [Reencodarr.CrfSearcher]
      :encode -> [Reencodarr.Encoder]
      _ -> []
    end)
    |> Enum.uniq()
  end

  # Configuration helpers
  defp node_mode do
    case {distributed_mode?(), web_enabled?()} do
      {false, true} -> :standalone_server
      {false, false} -> :standalone_headless  
      {true, _} -> if server_node?(), do: :distributed_server, else: :distributed_worker
    end
  end

  defp distributed_mode?, do: Application.get_env(:reencodarr, :distributed_mode, false)
  defp web_enabled?, do: Application.get_env(:reencodarr, :start_web_server, true)
  defp server_node?, do: not Application.get_env(:reencodarr, :worker_only, false)
  
  defp node_capabilities do
    Application.get_env(:reencodarr, :node_capabilities, [:crf_search, :encode])
  end

  defp cluster_topology do
    Application.get_env(:libcluster, :topologies, [])
  end
end
