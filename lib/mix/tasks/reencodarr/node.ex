defmodule Mix.Tasks.Reencodarr.Node do
  @moduledoc """
  Start Reencodarr in different node modes.

  ## Examples

      # Start server node with web UI
      mix reencodarr.node server --name reencodarr_server@tina.lan.325i.org

      # Start worker node
      mix reencodarr.node worker --name reencodarr_worker@tina.lan.325i.org --connect-to reencodarr_server@tina.lan.325i.org

      # Start specialized worker (encode only)
      mix reencodarr.node worker --name reencodarr_encoder@tina.lan.325i.org --capabilities encode

      # Start with automatic cluster discovery
      mix reencodarr.node server --name reencodarr_server@tina.lan.325i.org --cluster-hosts "reencodarr_worker@tina.lan.325i.org,reencodarr_encoder@tina.lan.325i.org"
  """

  use Mix.Task

  @shortdoc "Start Reencodarr node in server or worker mode"

  def run(args) do
    {opts, args} = OptionParser.parse!(args,
      strict: [
        name: :string,
        connect_to: :string,
        capabilities: :string,
        cookie: :string,
        cluster_hosts: :string
      ]
    )

    case args do
      ["server"] -> start_server_node(opts)
      ["worker"] -> start_worker_node(opts)
      _ -> print_usage()
    end
  end

  defp start_server_node(opts) do
    node_name = opts[:name] || "reencodarr_server@#{:inet.gethostname() |> elem(1) |> to_string()}.lan.325i.org"
    cookie = opts[:cookie] || :reencodarr_cluster

    configure_node(node_name, cookie)
    configure_capabilities([:crf_search, :encode])
    configure_libcluster(opts)

    Mix.shell().info("Starting Reencodarr server node: #{node_name}")
    Mix.Task.run("phx.server")
  end

  defp start_worker_node(opts) do
    node_name = opts[:name] || "reencodarr_worker@#{:inet.gethostname() |> elem(1) |> to_string()}.lan.325i.org"
    cookie = opts[:cookie] || :reencodarr_cluster
    connect_to = opts[:connect_to]
    capabilities = parse_capabilities(opts[:capabilities])

    # Configure environment before starting node
    Application.put_env(:reencodarr, :start_web_server, false)
    Application.put_env(:phoenix, :serve_endpoints, false)
    Application.put_env(:reencodarr, ReencodarrWeb.Endpoint, server: false)

    configure_node(node_name, cookie)
    configure_capabilities(capabilities)
    configure_libcluster(opts)

    Mix.shell().info("Starting Reencodarr worker node: #{node_name}")
    Mix.shell().info("Capabilities: #{inspect(capabilities)}")

    if connect_to do
      Mix.shell().info("Will connect to: #{connect_to}")
    end

    # Start only essential applications for worker nodes
    start_worker_applications()

    # Connect to server node if specified
    if connect_to do
      connect_to_node(connect_to)
    end

    # Keep the node alive
    :timer.sleep(:infinity)
  end

  defp start_worker_applications do
    # Configure environment to disable web server components
    Application.put_env(:phoenix, :serve_endpoints, false)
    Application.put_env(:reencodarr, ReencodarrWeb.Endpoint, server: false)

    # Start the full application but with web server disabled
    case Application.ensure_all_started(:reencodarr, :temporary) do
      {:ok, _} ->
        Mix.shell().info("Worker node applications started successfully")
      {:error, reason} ->
        Mix.shell().error("Failed to start worker applications: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp configure_node(node_name, cookie) do
    # Set node name and cookie
    # Use longnames for nodes with @hostname format
    node_type = if String.contains?(node_name, "@") do
      :longnames
    else
      :shortnames
    end

    # Set environment variable for other applications
    System.put_env("ELIXIR_NODE_NAME", node_name)

    # Start the node
    case Node.start(String.to_atom(node_name), node_type) do
      {:ok, _} ->
        Node.set_cookie(cookie)
        Mix.shell().info("Node started: #{Node.self()} (#{node_type})")
      {:error, reason} ->
        Mix.shell().error("Failed to start node: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp configure_capabilities(capabilities) do
    Application.put_env(:reencodarr, :node_capabilities, capabilities)
    Application.put_env(:reencodarr, :distributed_mode, true)
  end

  defp configure_libcluster(opts) do
    if cluster_hosts = opts[:cluster_hosts] do
      hosts =
        cluster_hosts
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_atom/1)

      # Update libcluster configuration
      topology_config = [
        reencodarr_cluster: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: hosts]
        ]
      ]

      Application.put_env(:libcluster, :topologies, topology_config)
      Mix.shell().info("Configured cluster auto-discovery for hosts: #{inspect(hosts)}")
    end
  end

  defp parse_capabilities(nil), do: [:crf_search, :encode]
  defp parse_capabilities(caps_string) do
    caps_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&normalize_capability/1)
  end

  defp normalize_capability("encoding"), do: :encode
  defp normalize_capability("crf_search"), do: :crf_search
  defp normalize_capability(cap), do: String.to_atom(cap)

  defp connect_to_node(server_node) do
    server_atom = String.to_atom(server_node)

    case Node.connect(server_atom) do
      true ->
        Mix.shell().info("Successfully connected to #{server_node}")
      false ->
        Mix.shell().error("Failed to connect to #{server_node}")
        System.halt(1)
    end
  end

  defp print_usage do
    Mix.shell().info("""
    Usage: mix reencodarr.node <mode> [options]

    Modes:
      server    Start server node with web UI
      worker    Start worker node

    Options:
      --name <name>           Node name (default: reencodarr_<mode>@hostname)
      --connect-to <node>     Connect to server node (worker mode only)
      --capabilities <caps>   Comma-separated capabilities: crf_search,encode
      --cookie <cookie>       Erlang cookie (default: reencodarr_cluster)

    Examples:
      mix reencodarr.node server --name reencodarr_server@tina.lan.325i.org
      mix reencodarr.node worker --name worker1@tina.lan.325i.org --connect-to reencodarr_server@tina.lan.325i.org
      mix reencodarr.node worker --capabilities encode --name encoder@tina.lan.325i.org
    """)
  end
end
