defmodule Reencodarr.Distributed.ClientSupervisor do
  @moduledoc """
  Supervisor for client-side (worker) processes.

  This supervisor manages processes that should run on both server and worker nodes,
  including the distributed coordinator, health monitor, and worker processes like
  CrfSearcher and Encoder.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Distributed coordination (runs on all nodes)
      Reencodarr.Distributed.Coordinator,
      # Health monitoring (runs on all nodes)
      Reencodarr.Distributed.HealthMonitor,
      # Worker processes (run on all nodes, but delegate work based on capabilities)
      Reencodarr.CrfSearcher,
      Reencodarr.Encoder,
      Reencodarr.AbAv1
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
