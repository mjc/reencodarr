import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :reencodarr, Reencodarr.Repo,
  database: "priv/reencodarr_test#{System.get_env("MIX_TEST_PARTITION")}.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Use single connection for test sandbox
  pool_size: 1,
  # Test-specific timeout for query execution
  timeout: 30_000,
  # Pool checkout timeout settings for handling concurrent test access
  queue_target: 5_000,
  queue_interval: 10_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :reencodarr, ReencodarrWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "A4oKjY781OHfIZq4JFru4uL2Z6REsXa7Y+0txG2z4wrWGsYYtMwXv/nFfqnqKTKo",
  server: false

# In test we don't send emails
config :reencodarr, Reencodarr.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Disable dev routes (LiveDashboard, mailbox preview) during test
config :reencodarr, dev_routes: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Mark test environment so async DB tasks run synchronously
config :reencodarr, env: :test

# Don't start Erlang distribution in tests — avoids duplicate_name conflicts
# with a running dev node and unnecessary epmd registration per test run.
config :reencodarr, start_distribution: false
