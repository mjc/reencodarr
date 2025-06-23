defmodule Mix.Tasks.Reencodarr.Node do
  @moduledoc """
  Start Reencodarr server or worker node.
  """

  use Mix.Task

  @shortdoc "Start server or worker node"

  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: [
      name: :string,
      connect_to: :string,
      capabilities: :string,
      cookie: :string
    ])

    case args do
      ["server"] -> start_server(opts)
      ["worker"] -> start_worker(opts)
      _ -> print_usage()
    end
  end

  defp start_server(opts) do
    configure_server()
    start_node(opts[:name] || "server@localhost", opts[:cookie] || :reencodarr)
    Mix.shell().info("Starting server: #{Node.self()}")
    Mix.Task.run("phx.server")
  end

  defp start_worker(opts) do
    configure_worker(opts)
    start_node(opts[:name] || "worker@localhost", opts[:cookie] || :reencodarr)
    Mix.shell().info("Starting worker: #{Node.self()}")
    
    Application.ensure_all_started(:reencodarr)
    
    if server = opts[:connect_to] do
      connect_and_register(server)
    end
    
    Process.sleep(:infinity)
  end

  defp configure_server do
    Application.put_env(:reencodarr, :distributed, true)
    Application.put_env(:reencodarr, :worker_only, false)
    Application.put_env(:reencodarr, :web, true)
    Application.put_env(:reencodarr, :capabilities, [:crf_search, :encode])
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
    node_type = if String.contains?(name, "@"), do: :longnames, else: :shortnames
    {:ok, _} = Node.start(String.to_atom(name), node_type)
    Node.set_cookie(cookie)
  end

  defp connect_and_register(server) do
    :timer.sleep(2000)
    Node.connect(String.to_atom(server))
    Reencodarr.Distributed.Coordinator.register_node()
  end

  defp parse_capabilities(nil), do: [:crf_search, :encode]
  defp parse_capabilities(caps) do
    caps |> String.split(",") |> Enum.map(&String.to_atom(String.trim(&1)))
  end

  defp print_usage do
    Mix.shell().info("""
    Usage: mix reencodarr.node <mode> [options]

    Modes:
      server    Start server with web interface
      worker    Start worker node

    Options:
      --name <name>           Node name
      --connect-to <server>   Server to connect to (worker only)
      --capabilities <caps>   Worker capabilities (comma-separated)
      --cookie <cookie>       Erlang cookie

    Examples:
      mix reencodarr.node server --name server@host
      mix reencodarr.node worker --name worker@host --connect-to server@host
    """)
  end
end
