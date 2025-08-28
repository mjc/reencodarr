defmodule Reencodarr.Server.Application do
  @moduledoc """
  Application module for server mode in distributed architecture.
  
  In server mode, this application handles:
  - Database operations and migrations
  - Web interface (Phoenix/LiveView)
  - Service integrations (Sonarr/Radarr APIs)
  - Work coordination and distribution to clients
  - Video analysis (can be local or distributed)
  - File management and post-processing
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Validate server mode configuration
    case Reencodarr.Core.Mode.validate_config() do
      :ok -> 
        Logger.info("Starting Reencodarr in server mode")
        start_server_children()
        
      {:error, reason} -> 
        Logger.error("Server mode configuration invalid: #{reason}")
        {:error, {:config_invalid, reason}}
    end
  end

  defp start_server_children do
    # Setup file logging
    setup_file_logging()

    children = [
      # Core infrastructure
      ReencodarrWeb.Telemetry,
      Reencodarr.Repo,
      {DNSCluster, query: Application.get_env(:reencodarr, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      {Finch, name: Reencodarr.Finch},
      
      # Distributed server components
      Reencodarr.Server.ClientManager,
      Reencodarr.Server.WorkCoordinator,
      Reencodarr.Server.FileTransferService,
      Reencodarr.Server.ResultHandler,
      
      # Analysis (server can handle this locally)
      Reencodarr.Analyzer.Supervisor,
      
      # Core services
      Reencodarr.ManualScanner,
      Reencodarr.Sync,
      
      # Task supervisor for async operations
      {Task.Supervisor, name: Reencodarr.TaskSupervisor},
      
      # Statistics and telemetry
      server_telemetry_children(),
      
      # Web interface - typically last
      ReencodarrWeb.Endpoint
    ]
    |> List.flatten()

    opts = [strategy: :one_for_one, name: Reencodarr.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp setup_file_logging do
    if Code.ensure_loaded?(LoggerBackends) do
      LoggerBackends.add({LoggerFileBackend, :file})
    end
  end

  defp server_telemetry_children do
    # Only start telemetry reporter in non-test environments
    if Application.get_env(:reencodarr, :env) != :test do
      [Reencodarr.TelemetryReporter]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ReencodarrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
