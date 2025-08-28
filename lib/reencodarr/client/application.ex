defmodule Reencodarr.Client.Application do
  @moduledoc """
  Application module for client mode in distributed architecture.
  
  In client mode, this application handles:
  - Processing tasks (CRF search, encoding) received from server
  - File transfer coordination with server
  - Binary validation (ab-av1, ffmpeg)
  - Result reporting back to server
  
  Clients have NO access to:
  - Database operations
  - Web interface
  - Service APIs (Sonarr/Radarr)
  - Original file storage (only temporary transferred files)
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Validate client mode configuration
    case Reencodarr.Core.Mode.validate_config() do
      :ok -> 
        validate_binaries_and_start()
        
      {:error, reason} -> 
        Logger.error("Client mode configuration invalid: #{reason}")
        {:error, {:config_invalid, reason}}
    end
  end

  defp validate_binaries_and_start do
    Logger.info("Starting Reencodarr in client mode")
    
    # Validate required binaries before starting services
    case Reencodarr.Client.BinaryValidator.validate_binaries() do
      :ok ->
        Logger.info("Binary validation passed, starting client services")
        start_client_children()
        
      {:error, reason} ->
        Logger.error("Binary validation failed: #{reason}")
        Logger.error("Client cannot start without required binaries")
        {:error, {:binaries_invalid, reason}}
    end
  end

  defp start_client_children do
    capabilities = Reencodarr.Core.Mode.node_capabilities()
    Logger.info("Client starting with capabilities: #{inspect(capabilities)}")

    children = [
      # Core infrastructure (minimal for clients)
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      {Task.Supervisor, name: Reencodarr.TaskSupervisor},
      
      # Client-specific services
      Reencodarr.Client.ServerConnection,
      Reencodarr.Client.FileManager,
      Reencodarr.Client.TaskManager,
      
      # Processing services based on capabilities
      processing_children(capabilities)
    ]
    |> List.flatten()

    opts = [strategy: :one_for_one, name: Reencodarr.Client.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp processing_children(capabilities) do
    children = []

    children =
      if :crf_search in capabilities do
        Logger.info("Client configured for CRF search capability")
        [Reencodarr.Client.CrfWorker | children]
      else
        children
      end

    children =
      if :encoding in capabilities do
        Logger.info("Client configured for encoding capability")
        [Reencodarr.Client.EncodeWorker | children]
      else
        children
      end

    # Note: :analysis capability would add AnalysisWorker
    # Note: :file_transfer capability is handled by FileManager (always present)

    children
  end
end
