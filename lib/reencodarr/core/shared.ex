defmodule Reencodarr.Core.Shared do
  @moduledoc """
  Shared data structures and types used across distributed components.
  
  This module defines common types and structures that need to be shared
  between server and client nodes in the distributed architecture.
  """

  @typedoc "Video processing task types"
  @type task_type :: :analysis | :crf_search | :encoding

  @typedoc "Video processing states"
  @type video_state :: 
    :needs_analysis 
    | :analyzed 
    | :crf_searching 
    | :crf_searched 
    | :encoding 
    | :encoded 
    | :failed

  @typedoc "Node capabilities for work distribution"
  @type node_capability :: :analysis | :crf_search | :encoding | :file_transfer

  @typedoc "Task message structure for client-server communication"
  @type task_message :: %{
    type: task_type(),
    id: String.t(),
    video_id: integer(),
    video_path: String.t(),
    params: map(),
    client_node: atom(),
    created_at: DateTime.t()
  }

  @typedoc "Task result structure for client-server communication"
  @type task_result :: %{
    task_id: String.t(),
    status: :success | :error,
    result: term(),
    error_reason: String.t() | nil,
    completed_at: DateTime.t()
  }

  @typedoc "Node registration info"
  @type node_info :: %{
    node: atom(),
    capabilities: [node_capability()],
    registered_at: DateTime.t(),
    last_heartbeat: DateTime.t(),
    status: :available | :busy | :unavailable
  }

  @typedoc "File transfer request"
  @type file_transfer :: %{
    id: String.t(),
    source_path: String.t(),
    destination_node: atom(),
    size: integer(),
    checksum: String.t()
  }

  @doc """
  Generate a unique task ID.
  """
  @spec generate_task_id() :: String.t()
  def generate_task_id do
    "task_#{System.system_time(:nanosecond)}_#{:rand.uniform(9999)}"
  end

  @doc """
  Generate a unique transfer ID.
  """
  @spec generate_transfer_id() :: String.t()
  def generate_transfer_id do
    "transfer_#{System.system_time(:nanosecond)}_#{:rand.uniform(9999)}"
  end

  @doc """
  Check if a task type is supported by given capabilities.
  """
  @spec task_supported?(task_type(), [node_capability()]) :: boolean()
  def task_supported?(:analysis, capabilities), do: :analysis in capabilities
  def task_supported?(:crf_search, capabilities), do: :crf_search in capabilities
  def task_supported?(:encoding, capabilities), do: :encoding in capabilities

  @doc """
  Convert task type to corresponding node capability.
  """
  @spec task_type_to_capability(task_type()) :: node_capability()
  def task_type_to_capability(:analysis), do: :analysis
  def task_type_to_capability(:crf_search), do: :crf_search
  def task_type_to_capability(:encoding), do: :encoding

  @doc """
  Validate task message structure.
  """
  @spec valid_task_message?(map()) :: boolean()
  def valid_task_message?(%{
    type: type,
    id: id,
    video_id: video_id,
    video_path: path,
    client_node: node
  }) when is_atom(type) and is_binary(id) and is_integer(video_id) and 
          is_binary(path) and is_atom(node) do
    type in [:analysis, :crf_search, :encoding]
  end
  def valid_task_message?(_), do: false

  @doc """
  Validate task result structure.
  """
  @spec valid_task_result?(map()) :: boolean()
  def valid_task_result?(%{
    task_id: task_id,
    status: status,
    completed_at: completed_at
  }) when is_binary(task_id) and status in [:success, :error] and 
          is_struct(completed_at, DateTime) do
    true
  end
  def valid_task_result?(_), do: false
end
