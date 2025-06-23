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

    node_name = opts[:name] || "reencodarr_worker@tina.lan.325i.org"
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
    end

    # Keep the node alive
    :timer.sleep(:infinity)
  end

  defp start_worker_applications do
    # Only start the essential dependencies - use safe starting
    ensure_started([:logger, :sasl, :os_mon, :runtime_tools, :telemetry, :phoenix_pubsub, :libcluster, :libring])

    # Start basic Reencodarr components manually
    {:ok, _} = Supervisor.start_link([
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: Reencodarr.ClusterSupervisor]]},
      Reencodarr.Distributed.Coordinator,
      Reencodarr.Distributed.HealthMonitor,
      Reencodarr.CrfSearcher,
      Reencodarr.Encoder,
      Reencodarr.AbAv1
    ], strategy: :one_for_one, name: Reencodarr.WorkerSupervisor)

    Mix.shell().info("Minimal worker node started successfully")
  end

  defp ensure_started(apps) do
    Enum.each(apps, fn app ->
      case :application.ensure_started(app) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} ->
          Mix.shell().info("Could not start #{app}: #{inspect(reason)}")
      end
    end)
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
end
