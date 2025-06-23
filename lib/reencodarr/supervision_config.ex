defmodule Reencodarr.SupervisionConfig do
  @moduledoc """
  Centralized configuration for the supervision tree.
  
  This module defines the supervision tree structure and provides
  helper functions to determine what components should run based
  on node configuration.
  """

  require Logger

  @valid_capabilities [:crf_search, :encode, :analyze]
  @valid_modes [:server_with_web, :server_headless, :worker]

  @doc """
  Determines the node mode based on application configuration.
  
  Returns one of:
  - :server_with_web - Full server with web interface
  - :server_headless - Server without web interface  
  - :worker - Worker node only
  """
  def node_mode do
    distributed_mode = Application.get_env(:reencodarr, :distributed_mode, false)
    start_web_server = Application.get_env(:reencodarr, :start_web_server, true)

    mode = case {distributed_mode, start_web_server} do
      {false, true} -> :server_with_web
      {false, false} -> :server_headless
      {true, true} -> :server_with_web
      {true, false} -> :worker
    end

    validate_mode!(mode)
    mode
  end

  @doc """
  Returns the supervisor specifications for the given node mode.
  """
  def supervisors_for_mode(mode) when mode in @valid_modes do
    case mode do
      :server_with_web -> 
        base_supervisors() ++ cluster_supervisors() ++ server_supervisors() ++ client_supervisors() ++ web_supervisors()
      
      :server_headless -> 
        base_supervisors() ++ cluster_supervisors() ++ server_supervisors() ++ client_supervisors()
      
      :worker -> 
        base_supervisors() ++ cluster_supervisors() ++ client_supervisors()
    end
  end

  @doc """
  Infrastructure components needed by all node types.
  """
  def base_supervisors do
    [Reencodarr.InfrastructureSupervisor]
  end

  @doc """
  Cluster/distributed components.
  """
  def cluster_supervisors do
    [Reencodarr.Distributed.ClusterInfrastructureSupervisor]
  end

  @doc """
  Server-only business logic components.
  """
  def server_supervisors do
    [Reencodarr.Distributed.ServerSupervisor]
  end

  @doc """
  Client/worker components that run on all nodes.
  """
  def client_supervisors do
    [Reencodarr.Distributed.ClientSupervisor]
  end

  @doc """
  Web interface components.
  """
  def web_supervisors do
    [Reencodarr.WebSupervisor]
  end

  @doc """
  Get node capabilities from configuration.
  """
  def node_capabilities do
    capabilities = Application.get_env(:reencodarr, :node_capabilities, [:crf_search, :encode])
    validate_capabilities!(capabilities)
    capabilities
  end

  @doc """
  Check if a capability is enabled for this node.
  """
  def has_capability?(capability) when capability in @valid_capabilities do
    capability in node_capabilities()
  end

  # Private validation functions

  defp validate_mode!(mode) when mode in @valid_modes, do: :ok
  defp validate_mode!(mode) do
    Logger.error("Invalid node mode: #{inspect(mode)}. Valid modes: #{inspect(@valid_modes)}")
    raise ArgumentError, "Invalid node mode: #{inspect(mode)}"
  end

  defp validate_capabilities!(capabilities) when is_list(capabilities) do
    invalid = Enum.reject(capabilities, &(&1 in @valid_capabilities))
    
    if invalid != [] do
      Logger.error("Invalid capabilities: #{inspect(invalid)}. Valid capabilities: #{inspect(@valid_capabilities)}")
      raise ArgumentError, "Invalid capabilities: #{inspect(invalid)}"
    end
    
    :ok
  end
  
  defp validate_capabilities!(capabilities) do
    Logger.error("Capabilities must be a list, got: #{inspect(capabilities)}")
    raise ArgumentError, "Capabilities must be a list"
  end
end
