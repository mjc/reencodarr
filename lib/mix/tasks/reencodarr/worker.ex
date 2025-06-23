defmodule Mix.Tasks.Reencodarr.Worker do
  @moduledoc """
  Start a worker node.

  Sets worker configuration and starts the application normally.
  """

  use Mix.Task

  @shortdoc "Start worker node"

  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [
      name: :string,
      connect_to: :string,
      capabilities: :string,
      cookie: :string
    ])

    # Set worker configuration
    Application.put_env(:reencodarr, :distributed_mode, true)
    Application.put_env(:reencodarr, :start_web_server, false)
    Application.put_env(:reencodarr, :node_capabilities, parse_capabilities(opts[:capabilities]))
    Application.put_env(:phoenix, :serve_endpoints, false)

    # Configure node if name provided
    if node_name = opts[:name] do
      cookie = case opts[:cookie] do
        nil -> :reencodarr
        str when is_binary(str) -> String.to_atom(str)
        atom when is_atom(atom) -> atom
      end
      configure_node(node_name, cookie)
    end

    # Connect to server if specified
    if server_node = opts[:connect_to] do
      # Schedule connection after application starts
      spawn(fn -> connect_to_server(server_node) end)
    end

    # Standard Elixir application start
    Mix.Task.run("run", ["--no-halt"])
  end

  defp configure_node(name, cookie) do
    # If node is not already started, start it
    if Node.self() == :nonode@nohost do
      node_type = if String.contains?(name, "@"), do: :longnames, else: :shortnames
      {:ok, _} = Node.start(String.to_atom(name), node_type)
    end
    
    # Always set the cookie (this can be done even if node is already started)
    Node.set_cookie(cookie)
  end

  defp connect_to_server(server_node) do
    # Wait for application to fully start
    Process.sleep(5000)
    
    IO.puts("Attempting to connect to server: #{server_node}")
    
    case Node.connect(String.to_atom(server_node)) do
      true -> 
        IO.puts("Successfully connected to server: #{server_node}")
      false -> 
        IO.puts("Failed to connect to server: #{server_node}")
        # Retry once after a delay
        Process.sleep(2000)
        case Node.connect(String.to_atom(server_node)) do
          true -> IO.puts("Successfully connected to server on retry: #{server_node}")
          false -> IO.puts("Final connection attempt failed: #{server_node}")
        end
    end
  end

  defp parse_capabilities(nil), do: [:crf_search, :encode]
  defp parse_capabilities(caps) do
    caps |> String.split(",") |> Enum.map(&String.to_atom(String.trim(&1)))
  end
end
