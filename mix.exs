defmodule Reencodarr.MixProject do
  use Mix.Project

  def project do
    [
      app: :reencodarr,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Reencodarr.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:broadway, "~> 1.1"},
      {:broadway_dashboard, "~> 0.4.0"},
      {:car_req, tag: "0.3.1", github: "carsdotcom/car_req"},
      {:contex, "~> 0.5.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:dns_cluster, "~> 0.2.0"},
      {:ecto_sql, "~> 3.10"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:finch, "~> 0.13"},
      {:floki, ">= 0.30.0", only: :test},
      {:live_debugger, "~> 0.3.0", only: :dev},
      {:meck, "~> 1.0", only: :test},
      {:gettext, "~> 0.20"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:jason, "~> 1.2"},
      {:logger_backends, "~> 1.0"},
      {:logger_file_backend, "~> 0.0.13"},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0.0-rc.1", override: true},
      {:postgrex, ">= 0.0.0"},
      {:req, "~> 0.5"},
      {:stream_data, "~> 1.2.0", only: :test},
      {:swoosh, "~> 1.5"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:tzdata, "~> 1.1"},
      {:nimble_csv, "~> 1.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind reencodarr", "esbuild reencodarr"],
      "assets.deploy": [
        "tailwind reencodarr --minify",
        "esbuild reencodarr --minify",
        "phx.digest"
      ]
    ]
  end
end
