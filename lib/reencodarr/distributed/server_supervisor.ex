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
      # Database repository (needed by most server processes)
      Reencodarr.Repo,
      # Task supervisor for server coordination tasks
      {Task.Supervisor, name: Reencodarr.TaskSupervisor},
      # Server-only business logic processes
      Reencodarr.Statistics,
      Reencodarr.ManualScanner,
      Reencodarr.Analyzer,
      Reencodarr.Sync
    ]

    # Use :one_for_one since these are mostly independent processes
    # Repo is first as other processes may depend on it
    Supervisor.init(children, strategy: :one_for_one)
  end
end
