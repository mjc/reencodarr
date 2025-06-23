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
    base_children = [
      ReencodarrWeb.Telemetry,
      Reencodarr.Repo,
      {DNSCluster, query: Application.get_env(:reencodarr, :dns_cluster_query) || :ignore},
      # Add libcluster for automatic node discovery
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: Reencodarr.ClusterSupervisor]]},
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Reencodarr.Finch},
      %{
        id: :worker_supervisor,
        start: {Supervisor, :start_link, [worker_children(), [strategy: :one_for_one]]}
      },
      Reencodarr.Statistics,
      # Start the TaskSupervisor
      {Task.Supervisor, name: Reencodarr.TaskSupervisor}
    ]

    # Only start endpoint if server is enabled
    if Application.get_env(:reencodarr, :start_web_server, true) do
      base_children ++ [ReencodarrWeb.Endpoint]
    else
      base_children
    end
  end

  defp worker_children do
    [
      # Add distributed coordinator first
      Reencodarr.Distributed.Coordinator,
      # Add health monitoring for distributed nodes
      Reencodarr.Distributed.HealthMonitor,
      Reencodarr.ManualScanner,
      Reencodarr.Analyzer,
      Reencodarr.CrfSearcher,
      Reencodarr.Encoder,
      Reencodarr.AbAv1,
      Reencodarr.Sync
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ReencodarrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
