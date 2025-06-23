defmodule Mix.Tasks.Reencodarr.Worker do
  @moduledoc """
  Start a Reencodarr worker node without Phoenix web server.
  """

  use Mix.Task

  @shortdoc "Start Reencodarr worker node"

  def run(args) do
    {opts, _args} = OptionParser.parse!(args,
      strict: [
        name: :string,
        connect_to: :string,
        capabilities: :string,
        cookie: :string
      ]
    )

    node_name = opts[:name] || "reencodarr_worker@#{:inet.gethostname() |> elem(1) |> to_string()}.lan.325i.org"
    cookie = opts[:cookie] || :reencodarr_cluster
    connect_to = opts[:connect_to]
    capabilities = parse_capabilities(opts[:capabilities])

    # Start the node
    configure_node(node_name, cookie)
    configure_capabilities(capabilities)

    Mix.shell().info("Starting Reencodarr worker node: #{node_name}")
    Mix.shell().info("Capabilities: #{inspect(capabilities)}")

    if connect_to do
      Mix.shell().info("Will connect to: #{connect_to}")
    end

    # Start worker applications
    start_worker_applications()

    # Connect to server node if specified
    if connect_to do
      connect_to_node(connect_to)
      # Give time for the application and processes to fully start
      :timer.sleep(3000)
      register_with_coordinator()
    end

    # Keep the node alive
    :timer.sleep(:infinity)
  end

  defp start_worker_applications do
    # Start essential dependencies manually for worker nodes
    essential_apps = [
      :crypto, :ssl, :public_key, :asn1,
      :logger, :sasl, :os_mon, :runtime_tools,
      :telemetry, :castore, :mint, :nimble_pool, :finch,
      :jason, :decimal, :phoenix_pubsub, :libcluster, :libring
    ]

    Enum.each(essential_apps, &Application.ensure_started/1)

    # Start minimal supervision tree for worker using our refactored supervisors
    {:ok, _} = Supervisor.start_link([
      # Core infrastructure
      Reencodarr.InfrastructureSupervisor,
      # Cluster infrastructure
      Reencodarr.Distributed.ClusterInfrastructureSupervisor,
      # Client processes (coordination + workers)
      Reencodarr.Distributed.ClientSupervisor
    ], strategy: :one_for_one, name: Reencodarr.WorkerSupervisor)

    Mix.shell().info("Worker node started successfully")
  end

  defp configure_node(node_name, cookie) do
    node_type = if String.contains?(node_name, "@") do
      :longnames
    else
      :shortnames
    end

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
    # Disable web server for worker nodes
    Application.put_env(:reencodarr, :start_web_server, false)
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

  defp register_with_coordinator do
    try do
      case Reencodarr.Distributed.Coordinator.register_node() do
        :ok ->
          Mix.shell().info("Successfully registered with coordinator")
        error ->
          Mix.shell().error("Failed to register with coordinator: #{inspect(error)}")
      end
    rescue
      error ->
        Mix.shell().error("Error during registration: #{inspect(error)}")
    end
  end
end
