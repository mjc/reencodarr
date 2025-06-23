defmodule Reencodarr.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Reencodarr.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  defp children do
    # Determine if we're running in distributed mode and what our role is
    distributed_mode = Application.get_env(:reencodarr, :distributed_mode, false)
    start_web_server = Application.get_env(:reencodarr, :start_web_server, true)

    # Check if this is a worker-only node
    is_worker_only = distributed_mode and not start_web_server

    base_children = [
      # Essential infrastructure
      ReencodarrWeb.Telemetry,
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      # Start the Finch HTTP client
      {Finch, name: Reencodarr.Finch},
      # Always start client processes (distributed coordination, workers)
      Reencodarr.Distributed.ClientSupervisor
    ]

    # Add server-specific infrastructure only for server nodes
    server_children = if is_worker_only do
      []
    else
      [
        Reencodarr.Repo,
        {DNSCluster, query: Application.get_env(:reencodarr, :dns_cluster_query) || :ignore},
        # Add libcluster for automatic node discovery
        {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: Reencodarr.ClusterSupervisor]]},
        # Server processes
        Reencodarr.Distributed.ServerSupervisor
      ]
    end

    # Add libcluster for workers too, but simpler setup
    worker_cluster_children = if is_worker_only do
      [{Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: Reencodarr.ClusterSupervisor]]}]
    else
      []
    end

    all_children = base_children ++ worker_cluster_children ++ server_children

    # Only start endpoint if server is enabled
    if start_web_server do
      all_children ++ [ReencodarrWeb.Endpoint]
    else
      all_children
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
