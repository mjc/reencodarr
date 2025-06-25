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
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Reencodarr.Finch},
      # Start to serve requests, typically the last entry
      ReencodarrWeb.Endpoint,
      %{
        id: :worker_supervisor,
        start: {Supervisor, :start_link, [worker_children(), [strategy: :one_for_one]]}
      },
      # Start the TaskSupervisor
      {Task.Supervisor, name: Reencodarr.TaskSupervisor}
    ]

    # Only start Statistics in non-test environments
    if Application.get_env(:reencodarr, :env) != :test do
      base_children ++ [Reencodarr.TelemetryReporter]
    else
      base_children
    end
  end

  defp worker_children do
    [
      Reencodarr.ManualScanner,
      Reencodarr.Analyzer,
      Reencodarr.CrfSearcher.Supervisor,
      Reencodarr.Encoder.Supervisor,
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
