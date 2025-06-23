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
    Application.put_env(:reencodarr, :distributed, true)
    Application.put_env(:reencodarr, :worker_only, true)
    Application.put_env(:reencodarr, :web, false)
    Application.put_env(:reencodarr, :capabilities, parse_capabilities(opts[:capabilities]))
    Application.put_env(:phoenix, :serve_endpoints, false)

    # Configure node if name provided
    if node_name = opts[:name] do
      configure_node(node_name, opts[:cookie] || :reencodarr)
    end

    # Standard Elixir application start
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
end
