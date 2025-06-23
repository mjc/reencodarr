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

    node_name = opts[:name] || default_node_name("worker")
    cookie = opts[:cookie] || :reencodarr_cluster
    connect_to = opts[:connect_to]
    capabilities = parse_capabilities(opts[:capabilities])

    # Configure for worker mode
    configure_worker_mode(capabilities)
    configure_node(node_name, cookie)

    Mix.shell().info("Starting Reencodarr worker node: #{node_name}")
    Mix.shell().info("Capabilities: #{inspect(capabilities)}")

    if connect_to do
      Mix.shell().info("Will connect to: #{connect_to}")
    end

    # Start the application
    start_application()

    # Connect to server if specified
    if connect_to do
      connect_to_node(connect_to)
      register_with_coordinator()
    end

    # Keep alive
    :timer.sleep(:infinity)
  end

  defp configure_worker_mode(capabilities) do
    # Worker node configuration
    Application.put_env(:reencodarr, :distributed_mode, true)
    Application.put_env(:reencodarr, :worker_only, true)
    Application.put_env(:reencodarr, :start_web_server, false)
    Application.put_env(:reencodarr, :node_capabilities, capabilities)
    Application.put_env(:phoenix, :serve_endpoints, false)
    Application.put_env(:reencodarr, ReencodarrWeb.Endpoint, server: false)
  end

  defp start_application do
    case Application.ensure_all_started(:reencodarr) do
      {:ok, _} ->
        Mix.shell().info("Worker applications started successfully")
      {:error, reason} ->
        Mix.shell().error("Failed to start applications: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp configure_node(node_name, cookie) do
    node_type = if String.contains?(node_name, "@"), do: :longnames, else: :shortnames

    case Node.start(String.to_atom(node_name), node_type) do
      {:ok, _} ->
        Node.set_cookie(cookie)
        Mix.shell().info("Node started: #{Node.self()} (#{node_type})")
      {:error, reason} ->
        Mix.shell().error("Failed to start node: #{inspect(reason)}")
        System.halt(1)
    end
  end

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
    :timer.sleep(2000)  # Give time for startup
    
    try do
      case Reencodarr.Distributed.Coordinator.register_node() do
        :ok ->
          Mix.shell().info("Successfully registered with coordinator")
        error ->
          Mix.shell().error("Failed to register: #{inspect(error)}")
      end
    rescue
      error ->
        Mix.shell().error("Error during registration: #{inspect(error)}")
    end
  end

  defp default_node_name(type) do
    hostname = :inet.gethostname() |> elem(1) |> to_string()
    "reencodarr_#{type}@#{hostname}.lan.325i.org"
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
end
