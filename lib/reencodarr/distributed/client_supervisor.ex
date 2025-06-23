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
      # Distributed coordination and health monitoring
      Reencodarr.Distributed.CoordinationSupervisor,
      # Worker processes based on node capabilities
      Reencodarr.WorkerProcessesSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
