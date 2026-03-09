defmodule Reencodarr.Analyzer.Supervisor do
  use Supervisor

  @moduledoc "Supervises analyzer-related processes using Broadway."

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    Reencodarr.Media.reset_orphaned_analyzing()

    children = [
      {Reencodarr.Analyzer.Broadway, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
