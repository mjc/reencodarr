defmodule Reencodarr.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Setup file logging
    setup_file_logging()

    opts = [strategy: :one_for_one, name: Reencodarr.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  defp setup_file_logging do
    if Code.ensure_loaded?(LoggerBackends) do
      LoggerBackends.add({LoggerFileBackend, :file})
    end
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
    base_workers = [
      Reencodarr.Sync,
      # Cache services for analyzer optimization
      Reencodarr.Analyzer.Core.FileStatCache,
      Reencodarr.Analyzer.MediaInfoCache
    ]

    # Only start Broadway-based workers in non-test environments to avoid process kill issues
    broadway_workers = [
      Reencodarr.AbAv1,
      Reencodarr.CrfSearcher.Supervisor,
      Reencodarr.Encoder.Supervisor
    ]

    # Only start Analyzer GenStage in non-test environments
    if Application.get_env(:reencodarr, :env) != :test do
      [Reencodarr.Analyzer.Supervisor | base_workers] ++
        broadway_workers
    else
      base_workers
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
