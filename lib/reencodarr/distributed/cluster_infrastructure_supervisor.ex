defmodule Reencodarr.Distributed.ClusterInfrastructureSupervisor do
  @moduledoc """
  Supervisor for cluster infrastructure processes.

  This supervisor manages distributed system infrastructure like libcluster
  for node discovery and DNS cluster configuration.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # DNS cluster for cloud environments
      {DNSCluster, query: Application.get_env(:reencodarr, :dns_cluster_query) || :ignore},
      # libcluster for automatic node discovery
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: Reencodarr.ClusterSupervisor]]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
