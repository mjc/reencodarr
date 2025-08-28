defmodule Reencodarr.Client.TaskManager do
  @moduledoc """
  Manages processing tasks received from the server.
  
  This GenServer receives task assignments from server, coordinates
  with appropriate workers (CRF, encoding), and reports results back.
  """

  use GenServer
  require Logger

  # For now, this is a stub that will be implemented in Phase 2
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("TaskManager: Starting (stub implementation)")
    {:ok, %{}}
  end
end
