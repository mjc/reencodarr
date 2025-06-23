defmodule Mix.Tasks.Reencodarr.Worker do
  @moduledoc """
  Start a Reencodarr worker node.
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

    # Configure as worker
    configure_worker(opts)
    
    # Start node
    start_node(opts[:name], opts[:cookie] || :reencodarr)
    
    Mix.shell().info("Starting worker: #{Node.self()}")
    
    # Start application
    Application.ensure_all_started(:reencodarr)
    
    # Connect and register
    if server = opts[:connect_to] do
      connect_to_server(server)
    end
    
    # Keep alive
    Process.sleep(:infinity)
  end

  defp configure_worker(opts) do
    capabilities = parse_capabilities(opts[:capabilities])
    
    Application.put_env(:reencodarr, :distributed, true)
    Application.put_env(:reencodarr, :worker_only, true)
    Application.put_env(:reencodarr, :web, false)
    Application.put_env(:reencodarr, :capabilities, capabilities)
    Application.put_env(:phoenix, :serve_endpoints, false)
  end

  defp start_node(name, cookie) do
    node_name = name || default_node_name()
    node_type = if String.contains?(node_name, "@"), do: :longnames, else: :shortnames
    
    {:ok, _} = Node.start(String.to_atom(node_name), node_type)
    Node.set_cookie(cookie)
  end

  defp connect_to_server(server) do
    :timer.sleep(2000)  # Let startup finish
    
    case Node.connect(String.to_atom(server)) do
      true -> 
        Mix.shell().info("Connected to #{server}")
        register_with_coordinator()
      false -> 
        Mix.shell().error("Failed to connect to #{server}")
    end
  end

  defp register_with_coordinator do
    try do
      Reencodarr.Distributed.Coordinator.register_node()
      Mix.shell().info("Registered with coordinator")
    rescue
      e -> Mix.shell().error("Registration failed: #{inspect(e)}")
    end
  end

  defp default_node_name do
    {:ok, hostname} = :inet.gethostname()
    "worker@#{hostname}"
  end

  defp parse_capabilities(nil), do: [:crf_search, :encode]
  defp parse_capabilities(caps) do
    caps
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end
end
