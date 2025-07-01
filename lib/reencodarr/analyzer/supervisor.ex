defmodule Reencodarr.Analyzer.Supervisor do
  use Supervisor

  @moduledoc "Supervises analyzer-related processes."

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    children = [
      %{
        id: Reencodarr.Analyzer.Producer,
        start: {Reencodarr.Analyzer.Producer, :start_link, []}
      },
      %{
        id: Reencodarr.Analyzer.Consumer,
        start: {Reencodarr.Analyzer.Consumer, :start_link, []}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
