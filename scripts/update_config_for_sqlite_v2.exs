#!/usr/bin/env elixir

defmodule ConfigUpdater do
  require Logger

  def run do
    Logger.info("Updating Reencodarr configuration for SQLite...")

    update_repo()
    update_dev_config()
    update_test_config()
    update_prod_config()

    Logger.info("Configuration update completed!")
    Logger.info("Next steps:")
    Logger.info("1. Run 'mix deps.get' to install SQLite dependencies")
    Logger.info("2. Delete your existing database: rm -f priv/reencodarr.db*")
    Logger.info("3. Run the migration script: elixir scripts/migrate_to_sqlite.exs")
    Logger.info("4. Test your application: mix phx.server")
  end

  defp update_repo do
    Logger.info("Updating lib/reencodarr/repo.ex...")

    repo_content = """
defmodule Reencodarr.Repo do
  use Ecto.Repo,
    otp_app: :reencodarr,
    adapter: Ecto.Adapters.SQLite3
end
"""

    File.write!("lib/reencodarr/repo.ex", repo_content)
    Logger.info("✓ Updated repo.ex to use SQLite3 adapter")
  end

  defp update_dev_config do
    Logger.info("Updating config/dev.exs...")

    dev_config = File.read!("config/dev.exs")

    # Find and replace the repo config section
    postgres_pattern = ~r/config :reencodarr, Reencodarr\.Repo,.*?pool_size: \d+/s

    sqlite_config = """
config :reencodarr, Reencodarr.Repo,
  database: "priv/reencodarr_dev.db",
  pool_size: 20,
  journal_mode: :wal,
  cache_size: -64000,
  temp_store: :memory,
  pool_timeout: 60_000"""

    updated_config = String.replace(dev_config, postgres_pattern, sqlite_config)

    File.write!("config/dev.exs", updated_config)
    Logger.info("✓ Updated dev.exs for SQLite")
  end

  defp update_test_config do
    Logger.info("Updating config/test.exs...")

    test_config = File.read!("config/test.exs")

    # Find and replace the repo config section
    postgres_pattern = ~r/config :reencodarr, Reencodarr\.Repo,.*?pool: Ecto\.Adapters\.SQL\.Sandbox/s

    sqlite_config = """
config :reencodarr, Reencodarr.Repo,
  database: ":memory:",
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox"""

    updated_config = String.replace(test_config, postgres_pattern, sqlite_config)

    File.write!("config/test.exs", updated_config)
    Logger.info("✓ Updated test.exs for SQLite")
  end

  defp update_prod_config do
    Logger.info("Updating config/runtime.exs...")

    runtime_config = File.read!("config/runtime.exs")

    # Replace the entire prod config block
    new_prod_config = """
if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise \"\"\"
      environment variable DATABASE_PATH is missing.
      For example: /app/data/reencodarr.db
      \"\"\"

  config :reencodarr, Reencodarr.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    journal_mode: :wal,
    cache_size: -64000,
    temp_store: :memory

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise \"\"\"
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      \"\"\"

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :reencodarr, ReencodarrWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Configure your mailer to use a different adapter.
  # swoosh_adapter = System.get_env("SWOOSH_ADAPTER") || "Swoosh.Adapters.Local"
  # config :reencodarr, Reencodarr.Mailer, adapter: swoosh_adapter

  # Disable swoosh api client as it is only required for production adapters.
  config :swoosh, :api_client, false
end"""

    # Replace the existing prod block
    prod_pattern = ~r/if config_env\(\) == :prod do.*?^end/ms
    updated_config = String.replace(runtime_config, prod_pattern, new_prod_config)

    File.write!("config/runtime.exs", updated_config)
    Logger.info("✓ Updated runtime.exs for SQLite")
  end
end

# Show current status and ask for confirmation
IO.puts("""
SQLite Configuration Update Script
==================================

This script will update your Reencodarr configuration files to use SQLite instead of PostgreSQL:

Files to be updated:
- lib/reencodarr/repo.ex (adapter change)
- config/dev.exs (database configuration)
- config/test.exs (database configuration)
- config/runtime.exs (production configuration)

Current dependencies in mix.exs should already be updated to ecto_sqlite3.

WARNING: This will modify your configuration files. Make sure to backup first!
""")

IO.write("Continue with configuration update? (y/N): ")
response = IO.read(:stdio, :line) |> String.trim() |> String.downcase()

if response in ["y", "yes"] do
  ConfigUpdater.run()
else
  IO.puts("Configuration update cancelled.")
end
