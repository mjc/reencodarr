defmodule Reencodarr.Client.ServerConnection do
  @moduledoc """
  Manages connection to the server node and handles registration.
  
  This GenServer maintains the connection to the server, handles
  reconnection logic, and registers client capabilities.
  """

  use GenServer
  require Logger

  # For now, this is a stub that will be implemented in Phase 1
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("ServerConnection: Starting (stub implementation)")
    {:ok, %{}}
  end
end
