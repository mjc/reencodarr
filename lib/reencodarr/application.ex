defmodule Reencodarr.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Log startup information
    mode = Reencodarr.SupervisionConfig.node_mode()
    capabilities = Reencodarr.SupervisionConfig.node_capabilities()
    
    Logger.info("Starting Reencodarr application", 
      mode: mode, 
      node: Node.self(),
      capabilities: capabilities
    )

    opts = [strategy: :one_for_one, name: Reencodarr.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  defp children do
    # Use centralized configuration to determine supervision tree
    mode = Reencodarr.SupervisionConfig.node_mode()
    Reencodarr.SupervisionConfig.supervisors_for_mode(mode)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ReencodarrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
