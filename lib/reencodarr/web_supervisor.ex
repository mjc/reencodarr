defmodule Reencodarr.WebSupervisor do
  @moduledoc """
  Supervisor for web/UI related processes.

  This supervisor manages the Phoenix web endpoint and any web-specific
  infrastructure that should only run on server nodes.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Phoenix web endpoint
      ReencodarrWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
