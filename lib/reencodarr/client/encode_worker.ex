defmodule Reencodarr.Client.EncodeWorker do
  @moduledoc """
  Handles encoding tasks on client nodes.
  
  This GenServer executes video encoding operations using local ab-av1
  binary on files transferred from the server.
  """

  use GenServer
  require Logger

  # For now, this is a stub that will be implemented in Phase 2
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("EncodeWorker: Starting (stub implementation)")
    {:ok, %{}}
  end
end
