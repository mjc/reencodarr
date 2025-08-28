defmodule Reencodarr.Server.ResultHandler do
  @moduledoc """
  Handles results received from client nodes.
  
  This GenServer processes task completion notifications from clients,
  updates the database, and triggers post-processing workflows.
  """

  use GenServer
  require Logger

  # For now, this is a stub that will be implemented in Phase 4
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("ResultHandler: Starting (stub implementation)")
    {:ok, %{}}
  end
end
