defmodule Reencodarr.Server.WorkCoordinator do
  @moduledoc """
  Coordinates work distribution to available client nodes.
  
  This GenServer receives processing requests and distributes them
  to appropriate client nodes based on capabilities and availability.
  """

  use GenServer
  require Logger

  # For now, this is a stub that will be implemented in Phase 2
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("WorkCoordinator: Starting (stub implementation)")
    {:ok, %{}}
  end
end
