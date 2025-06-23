defmodule Mix.Tasks.Reencodarr.Node do
  @moduledoc """
  Start server or worker node.

  Sets node configuration and uses standard Mix tasks.
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
    # Set server configuration
    Application.put_env(:reencodarr, :distributed_mode, true)
    Application.put_env(:reencodarr, :start_web_server, true)
    Application.put_env(:reencodarr, :node_capabilities, [:crf_search, :encode])

    # Configure node if name provided
    if node_name = opts[:name] do
      configure_node(node_name, opts[:cookie] || :reencodarr)
    end

    # Use standard Phoenix server task
    Mix.Task.run("phx.server")
  end

  defp start_worker(opts) do
    # Set worker configuration
    Application.put_env(:reencodarr, :distributed_mode, true)
    Application.put_env(:reencodarr, :start_web_server, false)
    Application.put_env(:reencodarr, :node_capabilities, parse_capabilities(opts[:capabilities]))
    Application.put_env(:phoenix, :serve_endpoints, false)

    # Configure node if name provided
    if node_name = opts[:name] do
      configure_node(node_name, opts[:cookie] || :reencodarr)
    end

    # Use standard run task
    Mix.Task.run("run", ["--no-halt"])
  end

  defp configure_node(name, cookie) do
    node_type = if String.contains?(name, "@"), do: :longnames, else: :shortnames
    {:ok, _} = Node.start(String.to_atom(name), node_type)
    Node.set_cookie(cookie)
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
      mix reencodarr.node worker --name worker@host
    """)
  end
end
