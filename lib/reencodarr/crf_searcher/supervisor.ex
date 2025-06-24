defmodule Reencodarr.CrfSearcher.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    children = [
      %{
        id: Reencodarr.CrfSearcher.Producer,
        start: {Reencodarr.CrfSearcher.Producer, :start_link, []}
      },
      %{
        id: Reencodarr.CrfSearcher.Consumer,
        start: {Reencodarr.CrfSearcher.Consumer, :start_link, []}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
