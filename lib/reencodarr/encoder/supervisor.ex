defmodule Reencodarr.Encoder.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    children = [
      %{
        id: Reencodarr.Encoder.Producer,
        start: {Reencodarr.Encoder.Producer, :start_link, []}
      },
      %{
        id: Reencodarr.Encoder.Consumer,
        start: {Reencodarr.Encoder.Consumer, :start_link, []}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
