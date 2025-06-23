defmodule Reencodarr.InfrastructureSupervisor do
  @moduledoc """
  Supervisor for core infrastructure processes.

  This supervisor manages essential infrastructure components that are needed
  by both server and worker nodes, such as telemetry, PubSub, HTTP client, etc.

  ## Children
  - `ReencodarrWeb.Telemetry` - Metrics collection and monitoring
  - `Phoenix.PubSub` - Inter-process communication
  - `Finch` - HTTP client for external requests

  ## Supervision Strategy
  `:one_for_one` - Each child is independent and can restart without affecting others.
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting infrastructure supervisor")
    
    children = [
      # Telemetry for metrics collection
      ReencodarrWeb.Telemetry,
      # PubSub for inter-process communication
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      # HTTP client for external requests
      {Finch, name: Reencodarr.Finch}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
