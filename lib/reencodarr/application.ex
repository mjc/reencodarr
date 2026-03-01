defmodule Reencodarr.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Setup file logging
    setup_file_logging()

    # Start Erlang distribution early so bin/rpc always works,
    # regardless of whether the app was started via `iex -S mix phx.server`
    # or `mix phx.server`. Previously this was only done in .iex.exs, which
    # meant distribution was never started in non-IEx invocations.
    maybe_start_distribution()

    opts = [strategy: :one_for_one, name: Reencodarr.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  defp setup_file_logging do
    if Code.ensure_loaded?(LoggerBackends) do
      LoggerBackends.add({LoggerFileBackend, :file})
    end
  end

  defp maybe_start_distribution do
    if !Node.alive?() and Application.get_env(:reencodarr, :start_distribution, true) do
      node_name = System.get_env("REENCODARR_NODE")
      cookie = System.get_env("REENCODARR_COOKIE", "reencodarr") |> String.to_atom()

      name =
        if node_name do
          String.to_atom(node_name)
        else
          {:ok, host} = :inet.gethostname()
          :"reencodarr@#{host}"
        end

      case Node.start(name, :shortnames) do
        {:ok, _} ->
          Node.set_cookie(cookie)
          require Logger
          Logger.info("Distribution started: #{Node.self()}")

        {:error, reason} ->
          require Logger
          Logger.warning("Failed to start distribution as #{name}: #{inspect(reason)}")
      end
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
      # DynamicSupervisor for port-holder processes (AbAv1.Encoder, AbAv1.CrfSearcher).
      # These are started on-demand and survive restarts of the worker GenServers.
      {DynamicSupervisor, name: Reencodarr.PortSupervisor, strategy: :one_for_one},
      %{
        id: :worker_supervisor,
        start: {Supervisor, :start_link, [worker_children(), [strategy: :one_for_one]]}
      },
      # Start the TaskSupervisor for general background tasks
      {Task.Supervisor, name: Reencodarr.TaskSupervisor},
      # Start the TaskSupervisor for web-related background tasks
      {Task.Supervisor, name: ReencodarrWeb.TaskSupervisor}
    ]

    base_children
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
      Reencodarr.Encoder.Supervisor,
      Reencodarr.Encoder.HealthCheck,
      Reencodarr.Dashboard.State
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
