defmodule Reencodarr.CrfSearcher.Supervisor do
  use Supervisor

  @moduledoc "Supervises CRF search-related processes."

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    children = [
      {Reencodarr.CrfSearcher.Broadway, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
