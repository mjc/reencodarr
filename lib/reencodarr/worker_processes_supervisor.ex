defmodule Reencodarr.WorkerProcessesSupervisor do
  @moduledoc """
  Supervisor for worker processes that perform actual work.

  This supervisor manages processes that can be distributed across nodes
  based on their capabilities, such as CRF searching, encoding, and analysis.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = build_worker_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_worker_children do
    base_children = [
      # Always start AbAv1 as it's used by multiple processes
      Reencodarr.AbAv1
    ]

    # Add capability-specific workers
    capability_children =
      Reencodarr.SupervisionConfig.node_capabilities()
      |> Enum.flat_map(&worker_for_capability/1)
      |> Enum.uniq()

    base_children ++ capability_children
  end

  defp worker_for_capability(:crf_search), do: [Reencodarr.CrfSearcher]
  defp worker_for_capability(:encode), do: [Reencodarr.Encoder]
  defp worker_for_capability(_), do: []
end
