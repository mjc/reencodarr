# Reencodarr Distributed Architecture (Future Design)

> **⚠️ NOTE**: This document describes a **future architectural vision** for Reencodarr, not the current implementation.
>
> **Current Architecture (as of October 2025)**:
> - Single monolithic application
> - SQLite database with WAL mode for concurrency
> - Broadway pipelines for processing coordination
> - All services run on a single node
>
> **This Document**: Outlines a proposed distributed client-server architecture for future scalability.

## Overview

This document outlines how to split Reencodarr into a distributed client-server architecture using Elixir's native distributed computing capabilities. The server will handle analysis and coordination, while clients will handle the computationally intensive CRF search and encoding operations.

## Current Monolithic Architecture

Currently, Reencodarr runs as a single application with three main pipelines:

1. **Analyzer** - Extracts video metadata using MediaInfo
2. **CRF Searcher** - Finds optimal encoding parameters using ab-av1
3. **Encoder** - Re-encodes videos with chosen parameters

All components share:
- Database (SQLite with video metadata, VMAF results)
- File system (original videos, temporary files)
- Web interface (Phoenix LiveView dashboard)
- Service integrations (Sonarr/Radarr APIs)

## Proposed Distributed Architecture

### Server Node (`reencodarr_server`)

**Responsibilities:**
- Video analysis (MediaInfo extraction)
- Database management (videos, VMAFs, libraries)
- Web dashboard and API
- Service integrations (Sonarr/Radarr)
- Work coordination and distribution
- File management and post-processing

**Components:**
- `Reencodarr.Analyzer.Broadway` - Analyzes videos with MediaInfo
- `Reencodarr.Server.WorkCoordinator` - Distributes work to clients
- `Reencodarr.Server.ClientManager` - Manages client connections
- `ReencodarrWeb.*` - Phoenix web interface
- `Reencodarr.Sync` - Service API integrations
- All database schemas and operations

### Client Nodes (`reencodarr_client`)

**Responsibilities:**
- CRF search operations on received files
- Video encoding operations on received files
- File transfer coordination with server
- Reporting results back to server

**Components:**
- `Reencodarr.Client.CrfWorker` - Handles CRF search tasks
- `Reencodarr.Client.EncodeWorker` - Handles encoding tasks
- `Reencodarr.Client.FileManager` - Manages file transfers from/to server
- `Reencodarr.Client.ServerConnection` - Maintains server connection

**Binary Requirements:**
- `ab-av1` - For CRF search and encoding operations
- `ffmpeg` (full build) - For video processing and VMAF calculations
- Platform-specific binaries for Windows and Linux support

**Isolation:**
- No direct database access (all data through server RPC calls)
- No direct filesystem access to server storage
- No direct service API access (Sonarr/Radarr through server)
- Operates only on files transferred from server

## Implementation Strategy

### Phase 1: Distributed Computing Foundation

#### 1.1 Node Configuration

**Server Node (mix.exs):**
```elixir
def project do
  [
    app: :reencodarr_server,
    version: "0.1.0",
    # ... existing config
  ]
end

def application do
  [
    mod: {Reencodarr.Server.Application, []},
    extra_applications: [:logger, :runtime_tools]
  ]
end
```

**Client Node (mix.exs):**
```elixir
def project do
  [
    app: :reencodarr_client,
    version: "0.1.0",
    # ... shared dependencies
  ]
end

def application do
  [
    mod: {Reencodarr.Client.Application, []},
    extra_applications: [:logger, :runtime_tools]
  ]
end
```

#### 1.2 Node Discovery and Connection

**Server-side Client Manager:**
```elixir
defmodule Reencodarr.Server.ClientManager do
  use GenServer
  require Logger

  @moduledoc """
  Manages connections to client nodes and tracks their capabilities.
  """

  defstruct clients: %{}, heartbeat_interval: 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_client(node, capabilities) do
    GenServer.call(__MODULE__, {:register_client, node, capabilities})
  end

  def get_available_clients(task_type) do
    GenServer.call(__MODULE__, {:get_available_clients, task_type})
  end

  def init(_opts) do
    # Monitor node connections
    :net_kernel.monitor_nodes(true, [node_type: :all])
    
    # Start heartbeat timer
    Process.send_after(self(), :heartbeat, 5000)
    
    {:ok, %__MODULE__{}}
  end

  def handle_call({:register_client, node, capabilities}, _from, state) do
    client_info = %{
      node: node,
      capabilities: capabilities,
      registered_at: System.system_time(:second),
      last_heartbeat: System.system_time(:second),
      status: :available
    }
    
    new_clients = Map.put(state.clients, node, client_info)
    Logger.info("Client registered: #{node} with capabilities: #{inspect(capabilities)}")
    
    {:reply, :ok, %{state | clients: new_clients}}
  end

  def handle_call({:get_available_clients, task_type}, _from, state) do
    available = 
      state.clients
      |> Enum.filter(fn {_node, client} ->
        client.status == :available and 
        task_type in client.capabilities
      end)
      |> Enum.map(fn {node, _client} -> node end)
    
    {:reply, available, state}
  end

  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node connected: #{node}")
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("Node disconnected: #{node}")
    new_clients = Map.delete(state.clients, node)
    {:noreply, %{state | clients: new_clients}}
  end

  def handle_info(:heartbeat, state) do
    # Send heartbeat to all connected clients
    Enum.each(state.clients, fn {node, _client} ->
      Node.spawn_link(node, fn ->
        GenServer.cast({__MODULE__, node()}, :heartbeat_response)
      end)
    end)
    
    # Schedule next heartbeat
    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, state}
  end

  def handle_cast(:heartbeat_response, state) do
    node = node()
    case Map.get(state.clients, node) do
      nil -> {:noreply, state}
      client ->
        updated_client = %{client | last_heartbeat: System.system_time(:second)}
        new_clients = Map.put(state.clients, node, updated_client)
        {:noreply, %{state | clients: new_clients}}
    end
  end
end
```

**Client-side Server Connection:**
```elixir
defmodule Reencodarr.Client.ServerConnection do
  use GenServer
  require Logger

  @server_node :"reencodarr_server@hostname"
  @capabilities [:crf_search, :encoding]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Connect to server node
    case Node.connect(@server_node) do
      true ->
        # Register with server
        register_with_server()
        {:ok, %{server_node: @server_node, connected: true}}
      
      false ->
        Logger.error("Failed to connect to server node: #{@server_node}")
        # Retry connection
        Process.send_after(self(), :retry_connection, 5000)
        {:ok, %{server_node: @server_node, connected: false}}
    end
  end

  def handle_info(:retry_connection, state) do
    case Node.connect(state.server_node) do
      true ->
        register_with_server()
        {:noreply, %{state | connected: true}}
      
      false ->
        Logger.warning("Retrying connection to server in 5s...")
        Process.send_after(self(), :retry_connection, 5000)
        {:noreply, state}
    end
  end

  defp register_with_server do
    GenServer.call(
      {Reencodarr.Server.ClientManager, @server_node},
      {:register_client, node(), @capabilities}
    )
    Logger.info("Registered with server node: #{@server_node}")
  end
end
```

### Phase 2: Work Distribution System

#### 2.1 Work Coordinator

```elixir
defmodule Reencodarr.Server.WorkCoordinator do
  use GenServer
  require Logger

  alias Reencodarr.Server.ClientManager
  alias Reencodarr.Media

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def distribute_crf_search(video) do
    GenServer.cast(__MODULE__, {:distribute_crf_search, video})
  end

  def distribute_encoding(vmaf) do
    GenServer.cast(__MODULE__, {:distribute_encoding, vmaf})
  end

  def handle_cast({:distribute_crf_search, video}, state) do
    case ClientManager.get_available_clients(:crf_search) do
      [] ->
        Logger.warning("No available clients for CRF search")
        # Optionally queue for later
        
      [client_node | _] ->
        task = %{
          type: :crf_search,
          video_id: video.id,
          video_path: video.path,
          vmaf_target: 95,
          client_node: client_node
        }
        
        send_task_to_client(client_node, task)
    end
    
    {:noreply, state}
  end

  def handle_cast({:distribute_encoding, vmaf}, state) do
    case ClientManager.get_available_clients(:encoding) do
      [] ->
        Logger.warning("No available clients for encoding")
        
      [client_node | _] ->
        task = %{
          type: :encoding,
          vmaf_id: vmaf.id,
          video_path: vmaf.video.path,
          crf: vmaf.crf,
          output_path: generate_output_path(vmaf),
          client_node: client_node
        }
        
        send_task_to_client(client_node, task)
    end
    
    {:noreply, state}
  end

  defp send_task_to_client(client_node, task) do
    Node.spawn_link(client_node, fn ->
      GenServer.cast(Reencodarr.Client.TaskManager, {:execute_task, task})
    end)
  end

  defp generate_output_path(vmaf) do
    temp_dir = Application.get_env(:reencodarr, :temp_dir, "/tmp")
    Path.join(temp_dir, "#{vmaf.video.id}_encoded.mkv")
  end
end
```

#### 2.2 Client Task Manager

```elixir
defmodule Reencodarr.Client.TaskManager do
  use GenServer
  require Logger

  alias Reencodarr.Client.{CrfWorker, EncodeWorker, FileManager}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def handle_cast({:execute_task, task}, state) do
    case task.type do
      :crf_search ->
        Task.start(fn -> execute_crf_search(task) end)
        
      :encoding ->
        Task.start(fn -> execute_encoding(task) end)
    end
    
    {:noreply, state}
  end

  defp execute_crf_search(task) do
    Logger.info("Starting CRF search for video #{task.video_id}")
    
    # Request file transfer from server
    server_node = :"reencodarr_server@hostname"
    case :rpc.call(server_node, Reencodarr.Server.FileTransferService, :transfer_file_to_client, [node(), task.video_path]) do
      {:ok, local_path} ->
        # Perform CRF search on local file
        case CrfWorker.search(local_path, task.vmaf_target) do
          {:ok, results} ->
            # Send results back to server
            send_results_to_server(task, {:crf_search_complete, results})
            
          {:error, reason} ->
            send_results_to_server(task, {:crf_search_failed, reason})
        end
        
        # Cleanup local file
        Reencodarr.Client.FileManager.cleanup_file(local_path)
        
      {:error, reason} ->
        Logger.error("Failed to transfer file for CRF search: #{reason}")
        send_results_to_server(task, {:crf_search_failed, "File transfer failed: #{reason}"})
    end
  end

  defp execute_encoding(task) do
    Logger.info("Starting encoding for VMAF #{task.vmaf_id}")
    
    # Request file transfer from server
    server_node = :"reencodarr_server@hostname"
    case :rpc.call(server_node, Reencodarr.Server.FileTransferService, :transfer_file_to_client, [node(), task.video_path]) do
      {:ok, local_path} ->
        temp_dir = Application.get_env(:reencodarr_client, :temp_dir, "/tmp/reencodarr_client")
        output_filename = "encoded_#{task.vmaf_id}_#{Path.basename(task.video_path)}"
        local_output_path = Path.join(temp_dir, output_filename)
        
        # Perform encoding on local file
        case EncodeWorker.encode(local_path, task.crf, local_output_path) do
          {:ok, encoded_path} ->
            # Transfer encoded file back to server
            case :rpc.call(server_node, Reencodarr.Server.FileTransferService, :receive_file_from_client, [node(), encoded_path, task.output_path]) do
              {:ok, server_path} ->
                send_results_to_server(task, {:encoding_complete, server_path})
                
              {:error, reason} ->
                Logger.error("Failed to transfer encoded file back to server: #{reason}")
                send_results_to_server(task, {:encoding_failed, "Result transfer failed: #{reason}"})
            end
            
            # Cleanup local files
            Reencodarr.Client.FileManager.cleanup_file(encoded_path)
            
          {:error, reason} ->
            send_results_to_server(task, {:encoding_failed, reason})
        end
        
        # Cleanup source file
        Reencodarr.Client.FileManager.cleanup_file(local_path)
        
      {:error, reason} ->
        Logger.error("Failed to transfer file for encoding: #{reason}")
        send_results_to_server(task, {:encoding_failed, "File transfer failed: #{reason}"})
    end
  end

  defp send_results_to_server(task, result) do
    server_node = :"reencodarr_server@hostname"
    Node.spawn_link(server_node, fn ->
      GenServer.cast(Reencodarr.Server.ResultHandler, {result, task})
    end)
  end
end
```

### Phase 3: File Management

#### 3.1 Server-to-Client File Transfer

Since clients have no direct access to the server's filesystem, database, or services, all files must be transferred from server to client before processing.

**Server-side File Transfer Service:**
```elixir
defmodule Reencodarr.Server.FileTransferService do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Transfer a file to a client node for processing.
  Returns the local path on the client where the file was stored.
  """
  def transfer_file_to_client(client_node, server_file_path) do
    GenServer.call(__MODULE__, {:transfer_to_client, client_node, server_file_path})
  end

  @doc """
  Receive a processed file back from a client.
  """
  def receive_file_from_client(client_node, client_file_path, server_destination_path) do
    GenServer.call(__MODULE__, {:receive_from_client, client_node, client_file_path, server_destination_path})
  end

  def handle_call({:transfer_to_client, client_node, server_file_path}, _from, state) do
    case File.stat(server_file_path) do
      {:ok, %{size: size}} when size > 100_000_000 ->
        # Use streaming for files > 100MB
        result = stream_file_to_client(client_node, server_file_path)
        {:reply, result, state}
        
      {:ok, _} ->
        # Use direct transfer for smaller files
        result = direct_transfer_to_client(client_node, server_file_path)
        {:reply, result, state}
        
      {:error, reason} ->
        {:reply, {:error, "File not accessible: #{reason}"}, state}
    end
  end

  def handle_call({:receive_from_client, client_node, client_file_path, server_destination_path}, _from, state) do
    # Always use streaming for encoded files (typically large)
    result = stream_file_from_client(client_node, client_file_path, server_destination_path)
    {:reply, result, state}
  end

  defp direct_transfer_to_client(client_node, server_file_path) do
    case File.read(server_file_path) do
      {:ok, file_data} ->
        filename = Path.basename(server_file_path)
        
        case :rpc.call(client_node, Reencodarr.Client.FileManager, :receive_file, [filename, file_data]) do
          {:ok, client_path} ->
            Logger.info("Direct transfer completed: #{server_file_path} -> #{client_node}:#{client_path}")
            {:ok, client_path}
            
          {:error, reason} ->
            {:error, "Client transfer failed: #{reason}"}
        end
        
      {:error, reason} ->
        {:error, "Failed to read file: #{reason}"}
    end
  end

  defp stream_file_to_client(client_node, server_file_path) do
    filename = Path.basename(server_file_path)
    chunk_size = 1_048_576  # 1MB chunks
    
    # Initialize transfer on client
    case :rpc.call(client_node, Reencodarr.Client.FileManager, :start_file_receive, [filename]) do
      {:ok, transfer_id} ->
        # Stream file in chunks
        case stream_file_chunks(client_node, server_file_path, transfer_id, chunk_size) do
          :ok ->
            # Finalize transfer
            case :rpc.call(client_node, Reencodarr.Client.FileManager, :finalize_file_receive, [transfer_id]) do
              {:ok, client_path} ->
                Logger.info("Streaming transfer completed: #{server_file_path} -> #{client_node}:#{client_path}")
                {:ok, client_path}
                
              {:error, reason} ->
                {:error, "Failed to finalize transfer: #{reason}"}
            end
            
          {:error, reason} ->
            {:error, "Streaming failed: #{reason}"}
        end
        
      {:error, reason} ->
        {:error, "Failed to initialize client transfer: #{reason}"}
    end
  end

  defp stream_file_chunks(client_node, server_file_path, transfer_id, chunk_size) do
    case File.open(server_file_path, [:read, :binary]) do
      {:ok, file} ->
        try do
          stream_chunks_loop(file, client_node, transfer_id, chunk_size, 0)
        after
          File.close(file)
        end
        
      {:error, reason} ->
        {:error, "Failed to open file: #{reason}"}
    end
  end

  defp stream_chunks_loop(file, client_node, transfer_id, chunk_size, chunk_num) do
    case IO.binread(file, chunk_size) do
      :eof ->
        :ok
        
      {:error, reason} ->
        {:error, "Read error: #{reason}"}
        
      chunk when is_binary(chunk) ->
        case :rpc.call(client_node, Reencodarr.Client.FileManager, :receive_chunk, [transfer_id, chunk_num, chunk]) do
          :ok ->
            stream_chunks_loop(file, client_node, transfer_id, chunk_size, chunk_num + 1)
            
          {:error, reason} ->
            {:error, "Chunk transfer failed: #{reason}"}
        end
    end
  end

  defp stream_file_from_client(client_node, client_file_path, server_destination_path) do
    # Initialize streaming from client
    case :rpc.call(client_node, Reencodarr.Client.FileManager, :start_file_send, [client_file_path]) do
      {:ok, transfer_id, total_chunks} ->
        case receive_file_chunks(client_node, transfer_id, server_destination_path, total_chunks) do
          :ok ->
            Logger.info("Streaming receive completed: #{client_node}:#{client_file_path} -> #{server_destination_path}")
            {:ok, server_destination_path}
            
          {:error, reason} ->
            {:error, "Failed to receive file: #{reason}"}
        end
        
      {:error, reason} ->
        {:error, "Failed to initialize client send: #{reason}"}
    end
  end

  defp receive_file_chunks(client_node, transfer_id, server_destination_path, total_chunks) do
    case File.open(server_destination_path, [:write, :binary]) do
      {:ok, file} ->
        try do
          receive_chunks_loop(file, client_node, transfer_id, 0, total_chunks)
        after
          File.close(file)
        end
        
      {:error, reason} ->
        {:error, "Failed to create destination file: #{reason}"}
    end
  end

  defp receive_chunks_loop(file, client_node, transfer_id, chunk_num, total_chunks) when chunk_num < total_chunks do
    case :rpc.call(client_node, Reencodarr.Client.FileManager, :send_chunk, [transfer_id, chunk_num]) do
      {:ok, chunk} ->
        case IO.binwrite(file, chunk) do
          :ok ->
            receive_chunks_loop(file, client_node, transfer_id, chunk_num + 1, total_chunks)
            
          {:error, reason} ->
            {:error, "Write error: #{reason}"}
        end
        
      {:error, reason} ->
        {:error, "Chunk receive failed: #{reason}"}
    end
  end

  defp receive_chunks_loop(_file, _client_node, _transfer_id, total_chunks, total_chunks) do
    :ok
  end
end
```

**Client-side File Manager:**
```elixir
defmodule Reencodarr.Client.FileManager do
  use GenServer
  require Logger

  defstruct transfers: %{}, next_transfer_id: 1

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Ensure temp directory exists
    temp_dir = Application.get_env(:reencodarr_client, :temp_dir, "/tmp/reencodarr_client")
    File.mkdir_p!(temp_dir)
    
    {:ok, %__MODULE__{}}
  end

  @doc """
  Receive a complete file directly (for smaller files).
  """
  def receive_file(filename, file_data) do
    GenServer.call(__MODULE__, {:receive_file, filename, file_data})
  end

  @doc """
  Start receiving a file in chunks (for larger files).
  """
  def start_file_receive(filename) do
    GenServer.call(__MODULE__, {:start_file_receive, filename})
  end

  @doc """
  Receive a chunk of a file being transferred.
  """
  def receive_chunk(transfer_id, chunk_num, chunk_data) do
    GenServer.call(__MODULE__, {:receive_chunk, transfer_id, chunk_num, chunk_data})
  end

  @doc """
  Finalize a chunked file transfer.
  """
  def finalize_file_receive(transfer_id) do
    GenServer.call(__MODULE__, {:finalize_file_receive, transfer_id})
  end

  @doc """
  Start sending a file back to server.
  """
  def start_file_send(file_path) do
    GenServer.call(__MODULE__, {:start_file_send, file_path})
  end

  @doc """
  Send a chunk of a file to server.
  """
  def send_chunk(transfer_id, chunk_num) do
    GenServer.call(__MODULE__, {:send_chunk, transfer_id, chunk_num})
  end

  @doc """
  Clean up local files after processing.
  """
  def cleanup_file(file_path) do
    GenServer.cast(__MODULE__, {:cleanup_file, file_path})
  end

  def handle_call({:receive_file, filename, file_data}, _from, state) do
    temp_dir = Application.get_env(:reencodarr_client, :temp_dir, "/tmp/reencodarr_client")
    local_path = Path.join(temp_dir, filename)
    
    case File.write(local_path, file_data) do
      :ok ->
        Logger.info("File received: #{filename} (#{byte_size(file_data)} bytes)")
        {:reply, {:ok, local_path}, state}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_file_receive, filename}, _from, state) do
    transfer_id = "transfer_#{state.next_transfer_id}"
    temp_dir = Application.get_env(:reencodarr_client, :temp_dir, "/tmp/reencodarr_client")
    local_path = Path.join(temp_dir, filename)
    
    transfer_info = %{
      id: transfer_id,
      filename: filename,
      local_path: local_path,
      chunks: %{},
      file_handle: nil
    }
    
    case File.open(local_path, [:write, :binary]) do
      {:ok, file_handle} ->
        updated_transfer = %{transfer_info | file_handle: file_handle}
        new_transfers = Map.put(state.transfers, transfer_id, updated_transfer)
        new_state = %{state | transfers: new_transfers, next_transfer_id: state.next_transfer_id + 1}
        
        {:reply, {:ok, transfer_id}, new_state}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:receive_chunk, transfer_id, chunk_num, chunk_data}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:reply, {:error, "Transfer not found"}, state}
        
      transfer ->
        case IO.binwrite(transfer.file_handle, chunk_data) do
          :ok ->
            Logger.debug("Received chunk #{chunk_num} for #{transfer_id}")
            {:reply, :ok, state}
            
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:finalize_file_receive, transfer_id}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:reply, {:error, "Transfer not found"}, state}
        
      transfer ->
        File.close(transfer.file_handle)
        new_transfers = Map.delete(state.transfers, transfer_id)
        new_state = %{state | transfers: new_transfers}
        
        Logger.info("File transfer completed: #{transfer.filename}")
        {:reply, {:ok, transfer.local_path}, new_state}
    end
  end

  def handle_call({:start_file_send, file_path}, _from, state) do
    case File.stat(file_path) do
      {:ok, %{size: size}} ->
        chunk_size = 1_048_576  # 1MB chunks
        total_chunks = div(size + chunk_size - 1, chunk_size)
        transfer_id = "send_#{state.next_transfer_id}"
        
        case File.open(file_path, [:read, :binary]) do
          {:ok, file_handle} ->
            transfer_info = %{
              id: transfer_id,
              file_path: file_path,
              file_handle: file_handle,
              chunk_size: chunk_size,
              total_chunks: total_chunks
            }
            
            new_transfers = Map.put(state.transfers, transfer_id, transfer_info)
            new_state = %{state | transfers: new_transfers, next_transfer_id: state.next_transfer_id + 1}
            
            {:reply, {:ok, transfer_id, total_chunks}, new_state}
            
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_chunk, transfer_id, chunk_num}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:reply, {:error, "Transfer not found"}, state}
        
      transfer ->
        # Seek to correct position
        :file.position(transfer.file_handle, chunk_num * transfer.chunk_size)
        
        case IO.binread(transfer.file_handle, transfer.chunk_size) do
          chunk when is_binary(chunk) ->
            {:reply, {:ok, chunk}, state}
            
          :eof ->
            {:reply, {:error, "Unexpected EOF"}, state}
            
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_cast({:cleanup_file, file_path}, state) do
    case File.rm(file_path) do
      :ok ->
        Logger.info("Cleaned up file: #{file_path}")
        
      {:error, reason} ->
        Logger.warning("Failed to cleanup file #{file_path}: #{reason}")
    end
    
    {:noreply, state}
  end
end
```

### Phase 4: Result Handling

#### 4.1 Server Result Handler

```elixir
defmodule Reencodarr.Server.ResultHandler do
  use GenServer
  require Logger

  alias Reencodarr.{Media, Telemetry}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def handle_cast({{:crf_search_complete, results}, task}, state) do
    Logger.info("Received CRF search results for video #{task.video_id}")
    
    # Store VMAF results in database
    Enum.each(results, fn vmaf_data ->
      Media.upsert_vmaf(%{
        video_id: task.video_id,
        crf: vmaf_data.crf,
        score: vmaf_data.score,
        percent: vmaf_data.percent,
        size: vmaf_data.size,
        time: vmaf_data.time,
        chosen: vmaf_data.chosen
      })
    end)

    # Update video state
    video = Media.get_video!(task.video_id)
    Media.update_video(video, %{state: :crf_searched})

    # Emit telemetry
    Telemetry.emit_crf_search_completed(task.video_id)
    
    {:noreply, state}
  end

  def handle_cast({{:encoding_complete, encoded_path}, task}, state) do
    Logger.info("Received encoding completion for VMAF #{task.vmaf_id}")
    
    # Handle post-processing (file moves, service updates, etc.)
    vmaf = Media.get_vmaf!(task.vmaf_id)
    case Reencodarr.PostProcessor.process_encoding_success(vmaf.video, encoded_path) do
      {:ok, :success} ->
        Media.update_video(vmaf.video, %{state: :encoded})
        
      {:error, reason} ->
        Logger.error("Post-processing failed: #{reason}")
    end
    
    {:noreply, state}
  end

  def handle_cast({{:crf_search_failed, reason}, task}, state) do
    Logger.error("CRF search failed for video #{task.video_id}: #{reason}")
    
    # Mark video as failed
    video = Media.get_video!(task.video_id)
    Media.update_video(video, %{state: :failed})
    
    {:noreply, state}
  end

  def handle_cast({{:encoding_failed, reason}, task}, state) do
    Logger.error("Encoding failed for VMAF #{task.vmaf_id}: #{reason}")
    
    # Handle encoding failure
    vmaf = Media.get_vmaf!(task.vmaf_id)
    Media.update_video(vmaf.video, %{state: :failed})
    
    {:noreply, state}
  end
end
```

### Phase 5: Configuration and Deployment

#### 5.1 Server Configuration

**config/distributed.exs:**
```elixir
import Config

config :reencodarr_server,
  mode: :server,
  node_name: "reencodarr_server@server-hostname",
  cookie: :reencodarr_cluster,
  client_heartbeat_interval: 30_000

# Keep existing database, web, and service configurations
config :reencodarr_server, Reencodarr.Repo,
  # ... existing database config

config :reencodarr_server, ReencodarrWeb.Endpoint,
  # ... existing web config
```

#### 5.2 Client Configuration

**config/distributed.exs:**
```elixir
import Config

config :reencodarr_client,
  mode: :client,
  server_node: "reencodarr_server@server-hostname",
  node_name: "reencodarr_client@#{System.get_env("HOSTNAME", "client")}",
  cookie: :reencodarr_cluster,
  capabilities: [:crf_search, :encoding],
  temp_dir: "/tmp/reencodarr_client",
  # Platform-specific binary paths
  ab_av1_path: System.get_env("AB_AV1_PATH") || detect_ab_av1_binary(),
  ffmpeg_path: System.get_env("FFMPEG_PATH") || detect_ffmpeg_binary()

# No database, web, or service API configuration for clients
# All data access goes through server RPC calls

# Helper functions for binary detection
defp detect_ab_av1_binary do
  case :os.type() do
    {:win32, _} -> "ab-av1.exe"
    {:unix, _} -> "ab-av1"
  end
end

defp detect_ffmpeg_binary do
  case :os.type() do
    {:win32, _} -> "ffmpeg.exe"
    {:unix, _} -> "ffmpeg"
  end
end
```

#### 5.3 Deployment Scripts

**Server Start Script (server_start.sh):**
```bash
#!/bin/bash
export NODE_NAME="reencodarr_server@$(hostname -f)"
export COOKIE="reencodarr_cluster"

_build/prod/rel/reencodarr_server/bin/reencodarr_server start
```

**Client Start Script - Linux (client_start.sh):**
```bash
#!/bin/bash
export NODE_NAME="reencodarr_client@$(hostname -f)"
export SERVER_NODE="reencodarr_server@server-hostname"
export COOKIE="reencodarr_cluster"

# Ensure required binaries are available
if ! command -v ab-av1 &> /dev/null; then
    echo "Error: ab-av1 binary not found in PATH"
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg binary not found in PATH"
    exit 1
fi

# Verify ffmpeg has required capabilities (libvmaf, libsvtav1)
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libsvtav1; then
    echo "Warning: ffmpeg may not have AV1 encoding support (libsvtav1)"
fi

if ! ffmpeg -hide_banner -filters 2>/dev/null | grep -q libvmaf; then
    echo "Warning: ffmpeg may not have VMAF support (libvmaf)"
fi

_build/prod/rel/reencodarr_client/bin/reencodarr_client start
```

**Client Start Script - Windows (client_start.bat):**
```batch
@echo off
set NODE_NAME=reencodarr_client@%COMPUTERNAME%
set SERVER_NODE=reencodarr_server@server-hostname
set COOKIE=reencodarr_cluster

REM Check for required binaries
where ab-av1.exe >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo Error: ab-av1.exe not found in PATH
    exit /b 1
)

where ffmpeg.exe >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo Error: ffmpeg.exe not found in PATH
    exit /b 1
)

REM Start the client
_build\prod\rel\reencodarr_client\bin\reencodarr_client.bat start
```

## Cross-Platform Support

### Binary Requirements

**All Client Nodes Must Have:**
- `ab-av1` - The primary encoding tool for CRF search and encoding
- `ffmpeg` (full build) - Required for video processing and VMAF calculations

**Critical ffmpeg Capabilities:**
- `libvmaf` - For VMAF quality calculations during CRF search
- `libsvtav1` - For AV1 encoding support
- Full codec support for input files (H.264, H.265, etc.)

### Nix/Flake Development Environment

The project includes a `flake.nix` that provides cross-platform development environments with all required dependencies:

**✅ Cross-Platform Compatibility:**
- **Linux (x86_64-linux)**: Full support with all dependencies
- **macOS ARM64 (aarch64-darwin)**: Full support using modern Apple SDK
- **Windows**: Not directly supported by Nix, use manual binary installation

**Development Environment Features:**
- Erlang/OTP 27 and Elixir 1.19.0-rc.0
- FFmpeg (full build) with libvmaf and AV1 support
- Platform-specific dependencies (inotify-tools on Linux, terminal-notifier on macOS)
- Development tools (git, gh, alejandra, nil, cspell)

**Usage:**
```bash
# Enter development shell with all dependencies
nix develop

# Build Docker image (Linux containers only)
nix build .#packages.dockerImage
```

**Client Deployment Considerations:**
- Nix flake provides consistent binary versions across development and server environments
- For production client deployment, consider extracting binaries from Nix store for distribution
- Windows clients must use manual binary installation as Nix doesn't support Windows

### Platform-Specific Considerations

### Platform-Specific Considerations

#### Linux Clients
- Use system package managers or static binaries
- Verify `ffmpeg` build includes required libraries
- Consider using FFmpeg static builds for consistency
- **Docker option available** for containerized deployment

**Installation Example:**
```bash
# Install ab-av1 (example using cargo)
cargo install ab-av1

# Install ffmpeg with required codecs (Ubuntu/Debian)
sudo apt install ffmpeg

# Verify capabilities
ffmpeg -encoders | grep libsvtav1
ffmpeg -filters | grep libvmaf
```

#### Windows Clients
- Use pre-compiled Windows binaries (.exe files)
- Ensure PATH includes binary directories
- Consider bundling binaries with client distribution
- **No Docker support** - use native Windows binaries

**Installation Example:**
```powershell
# Download ab-av1 Windows binary from GitHub releases
# Download FFmpeg full build from https://www.gyan.dev/ffmpeg/builds/

# Add to PATH or specify full paths in config
$env:AB_AV1_PATH = "C:\tools\ab-av1.exe"
$env:FFMPEG_PATH = "C:\tools\ffmpeg\bin\ffmpeg.exe"
```

#### Mac Clients
- Use Homebrew or pre-compiled macOS binaries
- Ensure binaries are signed/notarized for security
- **No Docker support** - use native macOS binaries

**Installation Example:**
```bash
# Install using Homebrew
brew install ab-av1
brew install ffmpeg

# Or download pre-compiled binaries
# Verify capabilities
ffmpeg -encoders | grep libsvtav1
ffmpeg -filters | grep libvmaf
```

### Binary Detection and Validation

```elixir
defmodule Reencodarr.Client.BinaryValidator do
  @moduledoc """
  Validates that required binaries are available and have necessary capabilities.
  """

  require Logger

  def validate_binaries do
    with :ok <- validate_ab_av1(),
         :ok <- validate_ffmpeg() do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_ab_av1 do
    ab_av1_path = Application.get_env(:reencodarr_client, :ab_av1_path)
    
    case System.cmd(ab_av1_path, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info("ab-av1 found: #{String.trim(output)}")
        :ok
        
      {_output, _code} ->
        {:error, "ab-av1 binary not found or not executable: #{ab_av1_path}"}
    end
  rescue
    _ -> {:error, "Failed to execute ab-av1 binary"}
  end

  defp validate_ffmpeg do
    ffmpeg_path = Application.get_env(:reencodarr_client, :ffmpeg_path)
    
    with :ok <- check_ffmpeg_executable(ffmpeg_path),
         :ok <- check_libvmaf_support(ffmpeg_path),
         :ok <- check_av1_support(ffmpeg_path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_ffmpeg_executable(ffmpeg_path) do
    case System.cmd(ffmpeg_path, ["-version"], stderr_to_stdout: true) do
      {output, 0} ->
        version_line = output |> String.split("\n") |> List.first()
        Logger.info("ffmpeg found: #{String.trim(version_line)}")
        :ok
        
      {_output, _code} ->
        {:error, "ffmpeg binary not found or not executable: #{ffmpeg_path}"}
    end
  rescue
    _ -> {:error, "Failed to execute ffmpeg binary"}
  end

  defp check_libvmaf_support(ffmpeg_path) do
    case System.cmd(ffmpeg_path, ["-hide_banner", "-filters"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "libvmaf") do
          Logger.info("ffmpeg has libvmaf support")
          :ok
        else
          {:error, "ffmpeg does not have libvmaf support - VMAF calculations will fail"}
        end
        
      {_output, _code} ->
        {:error, "Failed to check ffmpeg filters"}
    end
  end

  defp check_av1_support(ffmpeg_path) do
    case System.cmd(ffmpeg_path, ["-hide_banner", "-encoders"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "libsvtav1") do
          Logger.info("ffmpeg has AV1 encoding support")
          :ok
        else
          Logger.warning("ffmpeg may not have optimal AV1 encoding support")
          :ok  # Not critical since ab-av1 handles encoding
        end
        
      {_output, _code} ->
        {:error, "Failed to check ffmpeg encoders"}
    end
  end
end
```

### Client Startup Validation

```elixir
defmodule Reencodarr.Client.Application do
  use Application

  def start(_type, _args) do
    # Validate binaries before starting services
    case Reencodarr.Client.BinaryValidator.validate_binaries() do
      :ok ->
        Logger.info("Binary validation passed, starting client services")
        start_client_services()
        
      {:error, reason} ->
        Logger.error("Binary validation failed: #{reason}")
        Logger.error("Client cannot start without required binaries")
        System.halt(1)
    end
  end

  defp start_client_services do
    children = [
      Reencodarr.Client.ServerConnection,
      Reencodarr.Client.FileManager,
      Reencodarr.Client.TaskManager
    ]

    opts = [strategy: :one_for_one, name: Reencodarr.Client.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Binary Distribution Strategies

#### Option 1: System Dependencies
- Clients install binaries through system package managers (Linux/Mac) or manual download (Windows)
- Lightweight client releases
- Requires manual setup on each client machine
- **Recommended for Windows and Mac clients**

#### Option 2: Bundled Binaries
- Include platform-specific binaries in client releases
- Larger release packages but simpler deployment
- Consistent binary versions across all clients
- **Good for all platforms, especially Windows**

#### Option 3: Binary Download Service
- Server provides binary download endpoints
- Clients auto-download required binaries on first start
- Enables centralized binary version management
- **Useful for managed environments**

#### Option 4: Container Deployment (Linux Only)
- Docker containers with pre-installed binaries
- Simplest deployment for Linux server environments
- **Not available for Windows or Mac clients**

**Example Binary Bundling (mix.exs):**
```elixir
defp releases do
  [
    reencodarr_client_linux: [
      applications: [reencodarr_client: :permanent],
      steps: [:assemble, :tar, &copy_linux_binaries/1]
    ],
    reencodarr_client_windows: [
      applications: [reencodarr_client: :permanent],
      steps: [:assemble, :tar, &copy_windows_binaries/1]
    ],
    reencodarr_client_macos: [
      applications: [reencodarr_client: :permanent],
      steps: [:assemble, :tar, &copy_macos_binaries/1]
    ]
  ]
end

defp copy_linux_binaries(release) do
  bin_dir = Path.join(release.path, "bin")
  File.mkdir_p!(bin_dir)
  
  # Copy platform-specific binaries
  File.cp!("priv/binaries/linux/ab-av1", Path.join(bin_dir, "ab-av1"))
  File.cp!("priv/binaries/linux/ffmpeg", Path.join(bin_dir, "ffmpeg"))
  
  # Make executable
  File.chmod!(Path.join(bin_dir, "ab-av1"), 0o755)
  File.chmod!(Path.join(bin_dir, "ffmpeg"), 0o755)
  
  release
end

defp copy_windows_binaries(release) do
  bin_dir = Path.join(release.path, "bin")
  File.mkdir_p!(bin_dir)
  
  # Copy Windows binaries
  File.cp!("priv/binaries/windows/ab-av1.exe", Path.join(bin_dir, "ab-av1.exe"))
  File.cp!("priv/binaries/windows/ffmpeg.exe", Path.join(bin_dir, "ffmpeg.exe"))
  
  release
end

defp copy_macos_binaries(release) do
  bin_dir = Path.join(release.path, "bin")
  File.mkdir_p!(bin_dir)
  
  # Copy macOS binaries
  File.cp!("priv/binaries/macos/ab-av1", Path.join(bin_dir, "ab-av1"))
  File.cp!("priv/binaries/macos/ffmpeg", Path.join(bin_dir, "ffmpeg"))
  
  # Make executable
  File.chmod!(Path.join(bin_dir, "ab-av1"), 0o755)
  File.chmod!(Path.join(bin_dir, "ffmpeg"), 0o755)
  
  release
end
```

### Platform-Specific Temp Directory Handling

```elixir
defmodule Reencodarr.Client.PlatformUtils do
  @moduledoc """
  Platform-specific utilities for client operations.
  """

  def default_temp_dir do
    case :os.type() do
      {:win32, _} -> System.get_env("TEMP") || "C:/temp/reencodarr_client"
      {:unix, :darwin} -> "/tmp/reencodarr_client"  # macOS
      {:unix, _} -> "/tmp/reencodarr_client"        # Linux
    end
  end

  def ensure_temp_dir do
    temp_dir = Application.get_env(:reencodarr_client, :temp_dir) || default_temp_dir()
    File.mkdir_p!(temp_dir)
    temp_dir
  end

  def binary_extension do
    case :os.type() do
      {:win32, _} -> ".exe"
      {:unix, _} -> ""
    end
  end
end
```

### Container Deployment Option (Linux Only)

For easier deployment on Linux environments, consider Docker containers:

**Note:** Docker deployment is intended for Linux servers only. Windows and Mac clients should use native binary installations.

**Client Dockerfile:**
```dockerfile
FROM ubuntu:22.04

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Erlang/Elixir
RUN curl -fsSL https://packages.erlang-solutions.com/ubuntu/erlang_solutions.asc | apt-key add - \
    && echo "deb https://packages.erlang-solutions.com/ubuntu jammy contrib" | tee /etc/apt/sources.list.d/erlang-solutions.list \
    && apt-get update \
    && apt-get install -y erlang-base elixir \
    && rm -rf /var/lib/apt/lists/*

# Install ab-av1
RUN curl -L https://github.com/alexheretic/ab-av1/releases/latest/download/ab-av1-linux.tar.xz | tar -xJ -C /usr/local/bin/

# Install FFmpeg with required codecs
RUN apt-get update && apt-get install -y \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Copy client application
COPY _build/prod/rel/reencodarr_client /app
WORKDIR /app

# Verify binaries
RUN ab-av1 --version && ffmpeg -version

# Create temp directory
RUN mkdir -p /tmp/reencodarr_client

EXPOSE 4369 9100-9200
ENV NODE_NAME=reencodarr_client@$HOSTNAME
ENV COOKIE=reencodarr_cluster

CMD ["./bin/reencodarr_client", "start"]
```

**Docker Compose for Client Scaling:**
```yaml
version: '3.8'
services:
  reencodarr-client-1:
    build: .
    environment:
      - NODE_NAME=reencodarr_client_1@reencodarr-client-1
      - SERVER_NODE=reencodarr_server@reencodarr-server
      - COOKIE=reencodarr_cluster
    volumes:
      - /tmp/reencodarr_client_1:/tmp/reencodarr_client
    networks:
      - reencodarr-cluster

  reencodarr-client-2:
    build: .
    environment:
      - NODE_NAME=reencodarr_client_2@reencodarr-client-2
      - SERVER_NODE=reencodarr_server@reencodarr-server
      - COOKIE=reencodarr_cluster
    volumes:
      - /tmp/reencodarr_client_2:/tmp/reencodarr_client
    networks:
      - reencodarr-cluster

networks:
  reencodarr-cluster:
    driver: bridge
```

### Stage 1: Preparation
1. Refactor existing code to separate server and client concerns
2. Create shared modules for common data structures
3. Add distributed configuration options
4. ✅ **Fix cross-platform compatibility in flake.nix** - Updated Apple SDK dependencies and modernized flake structure for Linux and macOS ARM64 support
5. ✅ **Validate macOS compatibility and test suite** - Fixed Helper.temp_dir() bug, all 414 tests pass, server boots successfully with Nix PostgreSQL

### Stage 2: Dual Mode Operation
1. Add mode detection (`:server` or `:client` or `:monolithic`)
2. Keep existing monolithic mode as default
3. Add distributed components as optional

### Stage 3: Split Deployment
1. Create separate server and client releases
2. Test distributed operation in development
3. Gradually migrate production workloads

### Stage 4: Full Distribution
1. Remove monolithic mode
2. Optimize for distributed operation
3. Add advanced features (load balancing, failover)

## Benefits

### Scalability
- **Horizontal scaling**: Add more client nodes for increased processing capacity
- **Resource optimization**: Clients can be optimized for CPU/GPU intensive tasks
- **Workload isolation**: Analysis runs on server, encoding on dedicated clients

### Reliability
- **Fault tolerance**: Client failures don't affect server or other clients
- **Rolling updates**: Update clients without server downtime
- **Resource protection**: Server protected from resource-intensive encoding tasks

### Resource Isolation
- **Database isolation**: Clients never connect directly to PostgreSQL
- **Filesystem isolation**: Clients operate only on transferred files in temp directories
- **Service isolation**: Clients never call Sonarr/Radarr APIs directly
- **Network isolation**: All client-server communication through Elixir distribution

### Flexibility
- **Heterogeneous clients**: Different client types (CPU vs GPU optimized)
- **Geographic distribution**: Clients can be located near content storage
- **Elastic scaling**: Start/stop clients based on workload demands

## Considerations

### Network Requirements
- **Latency**: Elixir distribution requires low-latency connections
- **Bandwidth**: File transfers may require significant bandwidth
- **Security**: Use TLS for inter-node communication in production

### File Storage
- **Server-only storage**: All original files remain on server filesystem
- **Client isolation**: Clients receive temporary copies for processing
- **Transfer optimization**: Streaming for large files, direct transfer for small files
- **Automatic cleanup**: Clients automatically remove temporary files after processing

### Monitoring
- **Node health**: Monitor client node status and availability
- **Task distribution**: Track work distribution and completion
- **Performance**: Monitor encoding throughput across clients

## Future Enhancements

### Advanced Distribution
- **Client specialization**: GPU clients for VMAF, CPU clients for encoding
- **Load balancing**: Intelligent work distribution based on client capabilities
- **Queue management**: Persistent work queues with priorities

### Auto-scaling
- **Dynamic client registration**: Clients automatically join/leave cluster
- **Cloud integration**: Auto-scale client instances based on queue depth
- **Resource monitoring**: Scale based on CPU/memory utilization

### High Availability
- **Server clustering**: Multiple server nodes for redundancy
- **Work migration**: Transfer tasks between clients on failure
- **State replication**: Replicate critical state across server nodes

This distributed architecture leverages Elixir's strengths in distributed computing while maintaining the existing application logic and database design. The migration can be done gradually, allowing for testing and optimization at each stage.
