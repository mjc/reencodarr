defmodule Reencodarr.Application do
  @moduledoc """
  Main OTP Application for Reencodarr.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Reencodarr", node: Node.self())

    children =
      [
        # Core infrastructure
        ReencodarrWeb.Telemetry,
        {Phoenix.PubSub, name: Reencodarr.PubSub},
        {Finch, name: Reencodarr.Finch},

        # Cluster infrastructure
        cluster_supervisor(),
        coordination_processes(),
        worker_processes(),

        # Server processes (database, business logic)
        server_processes(),

        # Web interface
        web_endpoint()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: Reencodarr.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ReencodarrWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Cluster setup
  defp cluster_supervisor do
    if distributed?() do
      {Cluster.Supervisor, [cluster_config(), [name: Reencodarr.ClusterSupervisor]]}
    end
  end

  # Coordination processes
  defp coordination_processes do
    [
      # Always start coordinator (handles single-node clusters too)
      Reencodarr.Distributed.Coordinator,
      # Always start health monitor (needed for RPC calls from other nodes)
      Reencodarr.Distributed.HealthMonitor
    ]
  end

  # Worker processes based on capabilities
  defp worker_processes do
    workers = [Reencodarr.AbAv1] ++ capability_workers()

    %{
      id: Reencodarr.Workers,
      start:
        {Supervisor, :start_link, [workers, [strategy: :one_for_one, name: Reencodarr.Workers]]},
      type: :supervisor
    }
  end

  # Server-only processes
  defp server_processes do
    if server_mode?() do
      [
        Reencodarr.Repo,
        {Task.Supervisor, name: Reencodarr.TaskSupervisor},
        Reencodarr.Statistics,
        Reencodarr.ManualScanner,
        Reencodarr.Analyzer,
        Reencodarr.Sync
      ]
    else
      []
    end
  end

  # Web endpoint
  defp web_endpoint do
    if web_enabled?() do
      ReencodarrWeb.Endpoint
    end
  end

  # Configuration helpers
  defp distributed?, do: Application.get_env(:reencodarr, :distributed_mode, false)
  defp server_mode?, do: Application.get_env(:reencodarr, :start_web_server, true)
  defp web_enabled?, do: Application.get_env(:reencodarr, :start_web_server, true)

  defp capability_workers do
    Application.get_env(:reencodarr, :node_capabilities, [:crf_search, :encode])
    |> Enum.flat_map(fn
      :crf_search -> [Reencodarr.CrfSearcher]
      :encode -> [Reencodarr.Encoder]
      _ -> []
    end)
  end

  defp cluster_config do
    Application.get_env(:libcluster, :topologies, [])
  end
end
