defmodule Reencodarr.SupervisionTreeHelper do
  @moduledoc """
  Simple helpers for inspecting the supervision tree.
  """

  def print_tree do
    IO.puts("\n=== Supervision Tree ===")
    IO.puts("Node: #{Node.self()}")
    IO.puts("Config: #{inspect(config())}")

    print_children(Reencodarr.Supervisor, "")
  end

  def health_check do
    IO.puts("\n=== Health Check ===")

    case Process.whereis(Reencodarr.Supervisor) do
      nil -> IO.puts("❌ Supervisor not running!")
      pid ->
        IO.puts("✅ Supervisor running (#{inspect(pid)})")
        check_children(Reencodarr.Supervisor, "  ")
    end
  end

  defp print_children(supervisor, indent) do
    try do
      children = Supervisor.which_children(supervisor)
      Enum.each(children, fn {id, pid, type, _} ->
        status = if is_pid(pid) and Process.alive?(pid), do: "✅", else: "❌"
        IO.puts("#{indent}#{status} #{inspect(id)} (#{type})")

        if type == :supervisor and is_pid(pid) and Process.alive?(pid) do
          print_children(pid, indent <> "  ")
        end
      end)
    rescue
      _ -> IO.puts("#{indent}(unable to list)")
    end
  end

  defp check_children(supervisor, indent) do
    try do
      children = Supervisor.which_children(supervisor)
      healthy = Enum.count(children, fn {_, pid, _, _} -> is_pid(pid) and Process.alive?(pid) end)
      IO.puts("#{indent}Children: #{healthy}/#{length(children)} healthy")
    rescue
      _ -> IO.puts("#{indent}Unable to check")
    end
  end

  defp config do
    %{
      distributed: Application.get_env(:reencodarr, :distributed, false),
      worker_only: Application.get_env(:reencodarr, :worker_only, false),
      web: Application.get_env(:reencodarr, :web, true),
      capabilities: Application.get_env(:reencodarr, :capabilities, [])
    }
  end
end
