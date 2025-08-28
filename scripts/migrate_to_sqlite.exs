#!/usr/bin/env elixir

Mix.install([
  {:ecto_sql, "~> 3.10"},
  {:postgrex, ">= 0.0.0"},
  {:ecto_sqlite3, "~> 0.17"},
  {:jason, "~> 1.2"}
])

defmodule PostgresRepo do
  use Ecto.Repo,
    otp_app: :migration_script,
    adapter: Ecto.Adapters.Postgres
end

defmodule SqliteRepo do
  use Ecto.Repo,
    otp_app: :migration_script,
    adapter: Ecto.Adapters.SQLite3
end

defmodule MigrationScript do
  import Ecto.Query
  require Logger

  def run do
    Logger.info("Starting PostgreSQL to SQLite migration...")

    # Start repos
    {:ok, _} = PostgresRepo.start_link(postgres_config())
    {:ok, _} = SqliteRepo.start_link(sqlite_config())

    # Create SQLite database structure
    Logger.info("Creating SQLite database structure...")
    create_sqlite_structure()

    # Migrate data for each table
    Logger.info("Migrating data...")
    migrate_configs()
    migrate_libraries()
    migrate_videos()
    migrate_vmafs()
    migrate_video_failures()

    Logger.info("Migration completed successfully!")
  end

  defp postgres_config do
    [
      username: System.get_env("POSTGRES_USER", "postgres"),
      password: System.get_env("POSTGRES_PASSWORD", "postgres"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      database: System.get_env("POSTGRES_DB", "reencodarr_dev"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
    ]
  end

  defp sqlite_config do
    [
      database: System.get_env("SQLITE_DB", "priv/reencodarr.db"),
      pool_size: 1
    ]
  end

  defp create_sqlite_structure do
    # Create tables in SQLite
    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS configs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT,
        api_key TEXT,
        enabled BOOLEAN DEFAULT FALSE NOT NULL,
        service_type TEXT,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL
      )
    """)

    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS libraries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL
      )
    """)

    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS videos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        duration REAL,
        size BIGINT,
        video_codec TEXT,
        audio_codecs TEXT, -- JSON array as text
        resolution TEXT,
        bitrate REAL,
        mediainfo TEXT, -- JSON as text
        width INTEGER,
        height INTEGER,
        fps REAL,
        atmos BOOLEAN DEFAULT FALSE,
        max_audio_channels INTEGER,
        reencoded BOOLEAN DEFAULT FALSE,
        title TEXT,
        service_id INTEGER,
        service_type TEXT,
        library_id BIGINT,
        state TEXT DEFAULT 'needs_analysis',
        year INTEGER,
        release_year INTEGER,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (library_id) REFERENCES libraries(id)
      )
    """)

    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS vmafs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        crf REAL NOT NULL,
        score REAL NOT NULL,
        video_id BIGINT NOT NULL,
        chosen BOOLEAN DEFAULT FALSE,
        size BIGINT,
        time_seconds INTEGER,
        size_pct REAL,
        params TEXT, -- JSON array as text
        savings REAL,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (video_id) REFERENCES videos(id),
        UNIQUE(video_id, crf)
      )
    """)

    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS video_failures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id BIGINT NOT NULL,
        stage TEXT NOT NULL,
        error_message TEXT,
        error_details TEXT, -- JSON as text
        attempt_number INTEGER DEFAULT 1,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (video_id) REFERENCES videos(id)
      )
    """)

    # Create indexes
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_library_id ON videos(library_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_state ON videos(state)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_service ON videos(service_type, service_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_vmafs_video_id ON vmafs(video_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_vmafs_chosen ON vmafs(chosen)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_video_id ON video_failures(video_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_stage ON video_failures(stage)")
  end

  defp migrate_configs do
    Logger.info("Migrating configs...")

    configs = PostgresRepo.query!("""
      SELECT id, url, api_key, enabled, service_type, inserted_at, updated_at
      FROM configs ORDER BY id
    """)

    for row <- configs.rows do
      [id, url, api_key, enabled, service_type, inserted_at, updated_at] = row

      SqliteRepo.query!("""
        INSERT INTO configs (id, url, api_key, enabled, service_type, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      """, [id, url, api_key, enabled, service_type, inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(configs.rows)} configs")
  end

  defp migrate_libraries do
    Logger.info("Migrating libraries...")

    libraries = PostgresRepo.query!("""
      SELECT id, name, path, inserted_at, updated_at
      FROM libraries ORDER BY id
    """)

    for row <- libraries.rows do
      [id, name, path, inserted_at, updated_at] = row

      SqliteRepo.query!("""
        INSERT INTO libraries (id, name, path, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
      """, [id, name, path, inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(libraries.rows)} libraries")
  end

  defp migrate_videos do
    Logger.info("Migrating videos...")

    videos = PostgresRepo.query!("""
      SELECT id, path, duration, size, video_codec, audio_codecs, resolution, bitrate,
             mediainfo, width, height, fps, atmos, max_audio_channels, reencoded,
             title, service_id, service_type, library_id, state, year, release_year,
             inserted_at, updated_at
      FROM videos ORDER BY id
    """)

    for row <- videos.rows do
      [id, path, duration, size, video_codec, audio_codecs, resolution, bitrate,
       mediainfo, width, height, fps, atmos, max_audio_channels, reencoded,
       title, service_id, service_type, library_id, state, year, release_year,
       inserted_at, updated_at] = row

      # Convert arrays and JSON to text
      audio_codecs_json = if audio_codecs, do: Jason.encode!(audio_codecs), else: nil
      mediainfo_json = if mediainfo, do: Jason.encode!(mediainfo), else: nil
      state_str = if state, do: to_string(state), else: "needs_analysis"

      SqliteRepo.query!("""
        INSERT INTO videos (id, path, duration, size, video_codec, audio_codecs, resolution, bitrate,
                           mediainfo, width, height, fps, atmos, max_audio_channels, reencoded,
                           title, service_id, service_type, library_id, state, year, release_year,
                           inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [id, path, duration, size, video_codec, audio_codecs_json, resolution, bitrate,
            mediainfo_json, width, height, fps, atmos, max_audio_channels, reencoded,
            title, service_id, service_type, library_id, state_str, year, release_year,
            inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(videos.rows)} videos")
  end

  defp migrate_vmafs do
    Logger.info("Migrating vmafs...")

    vmafs = PostgresRepo.query!("""
      SELECT id, crf, score, video_id, chosen, size, time_seconds, size_pct,
             params, savings, inserted_at, updated_at
      FROM vmafs ORDER BY id
    """)

    for row <- vmafs.rows do
      [id, crf, score, video_id, chosen, size, time_seconds, size_pct,
       params, savings, inserted_at, updated_at] = row

      # Convert params array to JSON text
      params_json = if params, do: Jason.encode!(params), else: nil

      SqliteRepo.query!("""
        INSERT INTO vmafs (id, crf, score, video_id, chosen, size, time_seconds, size_pct,
                          params, savings, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [id, crf, score, video_id, chosen, size, time_seconds, size_pct,
            params_json, savings, inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(vmafs.rows)} vmafs")
  end

  defp migrate_video_failures do
    Logger.info("Migrating video_failures...")

    video_failures = PostgresRepo.query!("""
      SELECT id, video_id, stage, error_message, error_details, attempt_number,
             inserted_at, updated_at
      FROM video_failures ORDER BY id
    """)

    for row <- video_failures.rows do
      [id, video_id, stage, error_message, error_details, attempt_number,
       inserted_at, updated_at] = row

      # Convert error_details to JSON text if it's a map
      error_details_json = if error_details, do: Jason.encode!(error_details), else: nil

      SqliteRepo.query!("""
        INSERT INTO video_failures (id, video_id, stage, error_message, error_details, attempt_number,
                                   inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """, [id, video_id, stage, error_message, error_details_json, attempt_number,
            inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(video_failures.rows)} video_failures")
  end
end

# Usage information
IO.puts("""
PostgreSQL to SQLite Migration Script
=====================================

This script will migrate your Reencodarr data from PostgreSQL to SQLite.

Environment Variables (optional):
  POSTGRES_USER     - PostgreSQL username (default: postgres)
  POSTGRES_PASSWORD - PostgreSQL password (default: postgres)
  POSTGRES_HOST     - PostgreSQL host (default: localhost)
  POSTGRES_DB       - PostgreSQL database (default: reencodarr_dev)
  POSTGRES_PORT     - PostgreSQL port (default: 5432)
  SQLITE_DB         - SQLite database file (default: priv/reencodarr.db)

Usage:
  elixir scripts/migrate_to_sqlite.exs

WARNING: This will create a new SQLite database. Make sure to backup your data first!
""")

IO.write("Continue with migration? (y/N): ")
response = IO.read(:stdio, :line) |> String.trim() |> String.downcase()

if response in ["y", "yes"] do
  MigrationScript.run()
else
  IO.puts("Migration cancelled.")
end
