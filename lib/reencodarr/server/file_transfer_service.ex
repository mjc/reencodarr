defmodule Reencodarr.Server.FileTransferService do
  @moduledoc """
  Handles file transfers between server and client nodes.
  
  This GenServer manages file streaming for large videos and
  direct transfers for smaller files between server and clients.
  """

  use GenServer
  require Logger

  # For now, this is a stub that will be implemented in Phase 3
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("FileTransferService: Starting (stub implementation)")
    {:ok, %{}}
  end
end
