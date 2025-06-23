defmodule Reencodarr.SupervisionTreeHelper do
  @moduledoc """
  Helper functions for inspecting and debugging the supervision tree.
  """

  @doc """
  Prints the current supervision tree structure for debugging.
  """
  def print_tree do
    IO.puts("\n=== Reencodarr Supervision Tree ===")
    IO.puts("Node: #{Node.self()}")
    IO.puts("Mode: #{node_mode()}")
    IO.puts("Capabilities: #{inspect(node_capabilities())}")
    IO.puts("\nMain Supervisor (#{Reencodarr.Supervisor}):")
    
    print_supervisor_children(Reencodarr.Supervisor, "  ")
  end

  @doc """
  Performs a health check on the supervision tree.
  """
  def health_check do
    IO.puts("\n=== Supervision Tree Health Check ===")
    IO.puts("Node: #{Node.self()}")
    IO.puts("Mode: #{node_mode()}")
    
    case Process.whereis(Reencodarr.Supervisor) do
      nil ->
        IO.puts("❌ Main supervisor not running!")
        
      pid ->
        IO.puts("✅ Main supervisor running (#{inspect(pid)})")
        check_supervisor_health(Reencodarr.Supervisor, "  ")
    end
  end

  @doc """
  Lists all running processes in the supervision tree.
  """
  def list_processes do
    IO.puts("\n=== Running Processes ===")
    
    case Process.whereis(Reencodarr.Supervisor) do
      nil ->
        IO.puts("Main supervisor not running")
        
      _pid ->
        list_supervisor_processes(Reencodarr.Supervisor, "")
    end
  end

  # Private helpers

  defp print_supervisor_children(supervisor, indent) do
    try do
      children = Supervisor.which_children(supervisor)
      Enum.each(children, fn {id, pid, type, _modules} ->
        status = if is_pid(pid) and Process.alive?(pid), do: "✓", else: "✗"
        IO.puts("#{indent}├─ #{status} #{inspect(id)} (#{type})")
        
        # If it's a supervisor, recursively print its children
        if type == :supervisor and is_pid(pid) and Process.alive?(pid) do
          print_supervisor_children(pid, indent <> "│   ")
        end
      end)
    rescue
      _ -> IO.puts("#{indent}├─ (not accessible)")
    end
  end

  defp check_supervisor_health(supervisor, indent) do
    try do
      children = Supervisor.which_children(supervisor)
      healthy = Enum.count(children, fn {_id, pid, _type, _modules} ->
        is_pid(pid) and Process.alive?(pid)
      end)
      total = length(children)
      
      IO.puts("#{indent}└─ Children: #{healthy}/#{total} healthy")
      
      if healthy < total do
        Enum.each(children, fn {id, pid, _type, _modules} ->
          if not (is_pid(pid) and Process.alive?(pid)) do
            IO.puts("#{indent}   ❌ #{inspect(id)} - Not running")
          end
        end)
      end
    rescue
      _ -> IO.puts("#{indent}└─ Unable to check children")
    end
  end

  defp list_supervisor_processes(supervisor, indent) do
    try do
      children = Supervisor.which_children(supervisor)
      Enum.each(children, fn {id, pid, type, modules} ->
        status = if is_pid(pid) and Process.alive?(pid), do: "✓", else: "✗"
        IO.puts("#{indent}#{status} #{inspect(id)} (#{type}) - #{inspect(pid)} - #{inspect(modules)}")
        
        if type == :supervisor and is_pid(pid) and Process.alive?(pid) do
          list_supervisor_processes(pid, indent <> "  ")
        end
      end)
    rescue
      _ -> IO.puts("#{indent}(unable to list processes)")
    end
  end

  # Configuration helpers (simplified versions of what was in SupervisionConfig)
  defp node_mode do
    distributed_mode = Application.get_env(:reencodarr, :distributed_mode, false)
    web_enabled = Application.get_env(:reencodarr, :start_web_server, true)
    worker_only = Application.get_env(:reencodarr, :worker_only, false)

    case {distributed_mode, web_enabled, worker_only} do
      {false, true, _} -> :standalone_server
      {false, false, _} -> :standalone_headless  
      {true, _, false} -> :distributed_server
      {true, _, true} -> :distributed_worker
    end
  end

  defp node_capabilities do
    Application.get_env(:reencodarr, :node_capabilities, [:crf_search, :encode])
  end
end
