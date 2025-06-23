defmodule Reencodarr.Distributed.CoordinationSupervisor do
  @moduledoc """
  Supervisor for distributed coordination processes.

  This supervisor manages the processes responsible for cluster coordination,
  health monitoring, and distributed task management.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Distributed coordination using consistent hashing
      Reencodarr.Distributed.Coordinator,
      # Health monitoring for cluster nodes
      Reencodarr.Distributed.HealthMonitor
    ]

    # Use :rest_for_one strategy since HealthMonitor depends on Coordinator
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
