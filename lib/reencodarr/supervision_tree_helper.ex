defmodule Reencodarr.SupervisionTreeHelper do
  @moduledoc """
  Helper functions for inspecting and debugging the supervision tree.
  
  This module provides utilities to understand the current supervision
  tree structure, which processes are running, and their health status.
  """

  @doc """
  Prints the current supervision tree structure for debugging.
  """
  def print_tree do
    mode = Reencodarr.SupervisionConfig.node_mode()
    supervisors = Reencodarr.SupervisionConfig.supervisors_for_mode(mode)
    
    IO.puts("\n=== Reencodarr Supervision Tree ===")
    IO.puts("Node: #{Node.self()}")
    IO.puts("Mode: #{mode}")
    IO.puts("Capabilities: #{inspect(Reencodarr.SupervisionConfig.node_capabilities())}")
    IO.puts("\nSupervisors:")
    
    Enum.each(supervisors, fn supervisor ->
      IO.puts("  └─ #{inspect(supervisor)}")
      print_supervisor_children(supervisor, "    ")
    end)
  end

  defp print_supervisor_children(supervisor, indent) do
    try do
      children = Supervisor.which_children(supervisor)
      Enum.each(children, fn {id, pid, type, _modules} ->
        status = if is_pid(pid) and Process.alive?(pid), do: "✓", else: "✗"
        IO.puts("#{indent}├─ #{status} #{inspect(id)} (#{type})")
      end)
    rescue
      _ -> IO.puts("#{indent}├─ (not started)")
    end
  end

  @doc """
  Gets the health status of all supervisors.
  """
  def health_check do
    mode = Reencodarr.SupervisionConfig.node_mode()
    supervisors = Reencodarr.SupervisionConfig.supervisors_for_mode(mode)
    
    results = 
      supervisors
      |> Enum.map(fn supervisor ->
        status = 
          case Process.whereis(supervisor) do
            nil -> :not_started
            pid when is_pid(pid) -> 
              if Process.alive?(pid), do: :healthy, else: :dead
          end
        
        {supervisor, status}
      end)
    
    %{
      node: Node.self(),
      mode: mode,
      timestamp: DateTime.utc_now(),
      supervisors: results,
      overall: if(Enum.all?(results, fn {_, status} -> status == :healthy end), do: :healthy, else: :degraded)
    }
  end

  @doc """
  Restarts a specific supervisor if it's not healthy.
  """
  def restart_supervisor(supervisor) when is_atom(supervisor) do
    case Process.whereis(supervisor) do
      nil -> 
        {:error, :not_found}
      
      _pid ->
        case Supervisor.restart_child(Reencodarr.Supervisor, supervisor) do
          {:ok, _} -> {:ok, :restarted}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
