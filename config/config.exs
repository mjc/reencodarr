# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :reencodarr,
  ecto_repos: [Reencodarr.Repo],
  generators: [timestamp_type: :utc_datetime],
  env: config_env()

# Shared database configuration - SQLite performance tuning
config :reencodarr, Reencodarr.Repo,
  # Use binary format for arrays and maps (more efficient than JSON strings)
  array_type: :binary,
  map_type: :binary,
  # SQLite optimizations for concurrent operations across all environments
  pragma: [
    # Enable WAL mode for maximum concurrency
    journal_mode: "WAL",
    # WAL checkpoint settings for better write performance
    wal_autocheckpoint: 1000,
    # Use NORMAL sync mode with WAL for good performance/safety balance
    synchronous: "NORMAL",
    # Store temp tables in memory for better performance
    temp_store: "MEMORY",
    # Enable full mutex mode for better concurrency
    locking_mode: "NORMAL",
    # Allow reads during page writes
    read_uncommitted: true,
    # Increase busy timeout for concurrent operations (2 minutes)
    busy_timeout: 120_000,
    # Large cache size (256MB) for better performance
    cache_size: -256_000,
    # Large memory mapping (512MB) for better I/O performance
    mmap_size: 536_870_912
  ]

config :reencodarr, :temp_dir, Path.join(System.tmp_dir!(), "ab-av1")

# Configure file exclude patterns for video filtering
config :reencodarr, :exclude_patterns, [
  # Sample patterns - can be configured per environment
  # "**/sample/**",
  # "**/trailer/**",
  # "**/*sample*",
  # "**/*trailer*"
]

# Configures the endpoint
config :reencodarr, ReencodarrWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ReencodarrWeb.ErrorHTML, json: ReencodarrWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Reencodarr.PubSub,
  live_view: [signing_salt: "mUVP8kuz"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :reencodarr, Reencodarr.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  reencodarr: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  reencodarr: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :analyzer_progress,
    :normalized,
    :analyzer_files_count,
    :queue_length,
    :analyzing,
    :encoding,
    :crf_searching,
    :throughput,
    :percent,
    :stats,
    :vmaf_id,
    :base_args,
    :vmaf_params,
    :result_args,
    :input_count,
    :path_count,
    :path,
    :state,
    :exit_code,
    :result,
    :video_info
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Configure Broadway CRF Search Pipeline
config :reencodarr, Reencodarr.CrfSearcher.Broadway,
  rate_limit_messages: 10,
  rate_limit_interval: 1_000,
  batch_size: 1,
  batch_timeout: 5_000,
  crf_quality: 95

# Configure Broadway Encoder Pipeline
config :reencodarr, Reencodarr.Encoder.Broadway,
  rate_limit_messages: 5,
  rate_limit_interval: 1_000,
  batch_size: 1,
  batch_timeout: 10_000,
  # Encoding timeout in milliseconds (default: 2 hours for large files)
  # For very large 4K files or slow systems, consider increasing to 4-8 hours
  # 2 hours
  encoding_timeout: 7_200_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
