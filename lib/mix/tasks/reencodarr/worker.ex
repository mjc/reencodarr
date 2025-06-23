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
    # Start applications in the correct order
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:decimal)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:db_connection)
    {:ok, _} = Application.ensure_all_started(:ecto)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    # Start essential workers
    children = [
      Reencodarr.Repo,
      {Phoenix.PubSub, name: Reencodarr.PubSub},
      Reencodarr.Distributed.Coordinator
    ]

    # Add capability-specific workers
    capabilities = Application.get_env(:reencodarr, :node_capabilities, [])

    children = children ++
      (if :crf_search in capabilities, do: [Reencodarr.CrfSearcher], else: []) ++
      (if :encode in capabilities, do: [Reencodarr.Encoder], else: []) ++
      [Reencodarr.AbAv1]

    {:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one, name: WorkerSupervisor)

    Mix.shell().info("Worker node applications started successfully")
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
