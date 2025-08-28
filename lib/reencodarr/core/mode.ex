defmodule Reencodarr.Core.Mode do
  @moduledoc """
  Runtime mode detection and configuration for distributed architecture.
  
  This module determines whether the application should run in:
  - :monolithic - Traditional single-node mode (default)
  - :server - Distributed server mode (handles DB, web, coordination)
  - :client - Distributed client mode (handles processing tasks only)
  """

  @type mode :: :monolithic | :server | :client

  @doc """
  Get the current application mode.
  
  Mode is determined by configuration, with :monolithic as the default
  to maintain backward compatibility.
  """
  @spec current_mode() :: mode()
  def current_mode do
    Application.get_env(:reencodarr, :mode, :monolithic)
  end

  @doc """
  Check if running in monolithic mode.
  """
  @spec monolithic?() :: boolean()
  def monolithic?, do: current_mode() == :monolithic

  @doc """
  Check if running in server mode.
  """
  @spec server?() :: boolean()
  def server?, do: current_mode() == :server

  @doc """
  Check if running in client mode.
  """
  @spec client?() :: boolean()
  def client?, do: current_mode() == :client

  @doc """
  Check if running in any distributed mode (server or client).
  """
  @spec distributed?() :: boolean()
  def distributed?, do: current_mode() in [:server, :client]

  @doc """
  Get server node name for client connections.
  Only relevant in client mode.
  """
  @spec server_node() :: atom() | nil
  def server_node do
    case current_mode() do
      :client -> Application.get_env(:reencodarr, :server_node)
      _ -> nil
    end
  end

  @doc """
  Get node capabilities based on current mode.
  """
  @spec node_capabilities() :: [Reencodarr.Core.Shared.node_capability()]
  def node_capabilities do
    case current_mode() do
      :monolithic -> [:analysis, :crf_search, :encoding, :file_transfer]
      :server -> [:analysis, :file_transfer]
      :client -> Application.get_env(:reencodarr, :client_capabilities, [:crf_search, :encoding])
    end
  end

  @doc """
  Get the cluster cookie for distributed nodes.
  """
  @spec cluster_cookie() :: atom() | nil
  def cluster_cookie do
    if distributed?() do
      Application.get_env(:reencodarr, :cluster_cookie, :reencodarr_cluster)
    else
      nil
    end
  end

  @doc """
  Validate mode configuration.
  
  Returns :ok if configuration is valid for the current mode,
  {:error, reason} otherwise.
  """
  @spec validate_config() :: :ok | {:error, String.t()}
  def validate_config do
    case current_mode() do
      :monolithic -> 
        :ok
        
      :server -> 
        validate_server_config()
        
      :client -> 
        validate_client_config()
        
      invalid_mode -> 
        {:error, "Invalid mode: #{invalid_mode}. Must be :monolithic, :server, or :client"}
    end
  end

  defp validate_server_config do
    # Server mode requires database and web configuration
    required_configs = [
      {:reencodarr, Reencodarr.Repo},
      {:reencodarr, ReencodarrWeb.Endpoint}
    ]
    
    validate_required_configs(required_configs, "server")
  end

  defp validate_client_config do
    # Client mode requires server node and capabilities configuration
    case server_node() do
      nil -> 
        {:error, "Client mode requires :server_node configuration"}
      node when is_atom(node) -> 
        validate_client_capabilities()
      _ -> 
        {:error, "Server node must be an atom"}
    end
  end

  defp validate_client_capabilities do
    capabilities = node_capabilities()
    
    if Enum.empty?(capabilities) do
      {:error, "Client mode requires at least one capability"}
    else
      valid_capabilities = [:analysis, :crf_search, :encoding, :file_transfer]
      invalid = capabilities -- valid_capabilities
      
      if Enum.empty?(invalid) do
        :ok
      else
        {:error, "Invalid client capabilities: #{inspect(invalid)}"}
      end
    end
  end

  defp validate_required_configs(configs, mode) do
    missing = 
      configs
      |> Enum.filter(fn {app, key} -> 
        Application.get_env(app, key) == nil 
      end)
      |> Enum.map(fn {app, key} -> "#{app}.#{key}" end)
    
    if Enum.empty?(missing) do
      :ok
    else
      {:error, "#{String.capitalize(mode)} mode missing required configs: #{Enum.join(missing, ", ")}"}
    end
  end
end
