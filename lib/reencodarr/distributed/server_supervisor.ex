defmodule Reencodarr.Distributed.ServerSupervisor do
  @moduledoc """
  Supervisor for server-side processes.

  This supervisor manages processes that should only run on the server node,
  including the manual scanner, analyzer, sync process, and statistics.
  These processes coordinate work but don't perform the actual encoding/analysis.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Server-only processes that coordinate and manage work
      Reencodarr.ManualScanner,
      Reencodarr.Analyzer,
      Reencodarr.Sync,
      Reencodarr.Statistics,
      # Task supervisor for server coordination tasks
      {Task.Supervisor, name: Reencodarr.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
