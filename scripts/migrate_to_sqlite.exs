#!/usr/bin/env elixir

Mix.install([
  {:ecto_sql, "~> 3.10"},
  {:postgrex, ">= 0.0.0"},
  {:ecto_sqlite3, "~> 0.17"},
  {:jason, "~> 1.2"}
])

# Set log level to info to reduce verbose debug output
Logger.configure(level: :info)

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
        path TEXT NOT NULL,
        monitor BOOLEAN DEFAULT FALSE NOT NULL,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL
      )
    """)

    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS videos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        size BIGINT,
        bitrate INTEGER,
        duration REAL,
        width INTEGER,
        height INTEGER,
        frame_rate REAL,
        video_count INTEGER,
        audio_count INTEGER,
        text_count INTEGER,
        hdr TEXT,
        video_codecs TEXT,
        audio_codecs TEXT,
        text_codecs TEXT,
        atmos BOOLEAN DEFAULT FALSE,
        max_audio_channels INTEGER DEFAULT 0,
        title TEXT,
        service_id TEXT,
        service_type TEXT,
        library_id BIGINT,
        state TEXT NOT NULL,
        content_year INTEGER,
        mediainfo TEXT,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (library_id) REFERENCES libraries(id)
      )
    """)

    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS vmafs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        score REAL,
        crf REAL,
        video_id BIGINT NOT NULL,
        chosen BOOLEAN DEFAULT FALSE NOT NULL,
        size TEXT,
        percent REAL,
        time INTEGER,
        savings BIGINT,
        target INTEGER DEFAULT 95,
        params TEXT,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (video_id) REFERENCES videos(id),
        UNIQUE(crf, video_id)
      )
    """)

    SqliteRepo.query!("""
      CREATE TABLE IF NOT EXISTS video_failures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id BIGINT NOT NULL,
        failure_stage TEXT NOT NULL,
        failure_category TEXT NOT NULL,
        failure_code TEXT,
        failure_message TEXT NOT NULL,
        system_context TEXT,
        retry_count INTEGER DEFAULT 0,
        resolved BOOLEAN DEFAULT FALSE,
        resolved_at DATETIME,
        inserted_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (video_id) REFERENCES videos(id)
      )
    """)

    # Create indexes
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_library_id ON videos(library_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_state ON videos(state)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_service ON videos(service_type, service_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_content_year ON videos(content_year)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_state_size ON videos(state, size)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_videos_state_updated_at ON videos(state, updated_at)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_vmafs_video_id ON vmafs(video_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_vmafs_chosen ON vmafs(chosen)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_video_id ON video_failures(video_id)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_failure_stage ON video_failures(failure_stage)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_failure_category ON video_failures(failure_category)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_resolved ON video_failures(resolved)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_video_id_resolved ON video_failures(video_id, resolved)")
    SqliteRepo.query!("CREATE INDEX IF NOT EXISTS idx_video_failures_inserted_at ON video_failures(inserted_at)")
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
      SELECT id, path, monitor, inserted_at, updated_at
      FROM libraries ORDER BY id
    """)

    for row <- libraries.rows do
      [id, path, monitor, inserted_at, updated_at] = row

      SqliteRepo.query!("""
        INSERT INTO libraries (id, path, monitor, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
      """, [id, path, monitor, inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(libraries.rows)} libraries")
  end

  defp migrate_videos do
    Logger.info("Migrating videos...")

    videos = PostgresRepo.query!("""
      SELECT id, path, size, bitrate, duration, width, height, frame_rate, video_count,
             audio_count, text_count, hdr, video_codecs, audio_codecs, text_codecs,
             atmos, max_audio_channels, title, service_id, service_type, library_id,
             state, content_year, mediainfo, inserted_at, updated_at
      FROM videos ORDER BY id
    """)

    for row <- videos.rows do
      [id, path, size, bitrate, duration, width, height, frame_rate, video_count,
       audio_count, text_count, hdr, video_codecs, audio_codecs, text_codecs,
       atmos, max_audio_channels, title, service_id, service_type, library_id,
       state, content_year, mediainfo, inserted_at, updated_at] = row

      # Convert arrays and JSON to text
      video_codecs_json = if video_codecs, do: Jason.encode!(video_codecs), else: nil
      audio_codecs_json = if audio_codecs, do: Jason.encode!(audio_codecs), else: nil
      text_codecs_json = if text_codecs, do: Jason.encode!(text_codecs), else: nil
      mediainfo_json = if mediainfo, do: Jason.encode!(mediainfo), else: nil
      state_str = if state, do: to_string(state), else: "needs_analysis"

      SqliteRepo.query!("""
        INSERT INTO videos (id, path, size, bitrate, duration, width, height, frame_rate, video_count,
                           audio_count, text_count, hdr, video_codecs, audio_codecs, text_codecs,
                           atmos, max_audio_channels, title, service_id, service_type, library_id,
                           state, content_year, mediainfo, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [id, path, size, bitrate, duration, width, height, frame_rate, video_count,
            audio_count, text_count, hdr, video_codecs_json, audio_codecs_json, text_codecs_json,
            atmos, max_audio_channels, title, service_id, service_type, library_id,
            state_str, content_year, mediainfo_json, inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(videos.rows)} videos")
  end

  defp migrate_vmafs do
    Logger.info("Migrating vmafs...")

    vmafs = PostgresRepo.query!("""
      SELECT id, score, crf, video_id, chosen, size, percent, time, savings, target,
             params, inserted_at, updated_at
      FROM vmafs ORDER BY id
    """)

    for row <- vmafs.rows do
      [id, score, crf, video_id, chosen, size, percent, time, savings, target,
       params, inserted_at, updated_at] = row

      # Convert params array to JSON text
      params_json = if params, do: Jason.encode!(params), else: nil

      SqliteRepo.query!("""
        INSERT INTO vmafs (id, score, crf, video_id, chosen, size, percent, time, savings, target,
                          params, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [id, score, crf, video_id, chosen, size, percent, time, savings, target,
            params_json, inserted_at, updated_at])
    end

    Logger.info("Migrated #{length(vmafs.rows)} vmafs")
  end

  defp migrate_video_failures do
    Logger.info("Migrating video_failures...")

    video_failures = PostgresRepo.query!("""
      SELECT id, video_id, failure_stage, failure_category, failure_code, failure_message,
             system_context, retry_count, resolved, resolved_at, inserted_at, updated_at
      FROM video_failures ORDER BY id
    """)

    for row <- video_failures.rows do
      [id, video_id, failure_stage, failure_category, failure_code, failure_message,
       system_context, retry_count, resolved, resolved_at, inserted_at, updated_at] = row

      # Convert system_context to JSON text if it's a map
      system_context_json = if system_context, do: Jason.encode!(system_context), else: nil

      SqliteRepo.query!("""
        INSERT INTO video_failures (id, video_id, failure_stage, failure_category, failure_code, failure_message,
                                   system_context, retry_count, resolved, resolved_at, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [id, video_id, failure_stage, failure_category, failure_code, failure_message,
            system_context_json, retry_count, resolved, resolved_at, inserted_at, updated_at])
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
