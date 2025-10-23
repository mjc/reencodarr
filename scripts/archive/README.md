# PostgreSQL to SQLite Migration Scripts (Archive)

This directory contains scripts used for the historical migration from PostgreSQL to SQLite.

## Migration Completion

The migration to SQLite was completed successfully. These scripts are archived for:
- Historical reference
- Understanding the migration process
- Potential rollback scenarios (though not recommended)

## Current Database

Reencodarr now uses **SQLite with WAL mode** for:
- Simplified deployment (no separate database service)
- Better concurrency with WAL mode
- Reduced operational complexity
- Embedded database with the application

## Configuration

Current SQLite configuration is in `config/config.exs` with optimizations:
- WAL (Write-Ahead Logging) mode for concurrent access
- 256MB cache size
- 512MB memory mapping
- 2-minute busy timeout

## Scripts in This Archive

- `migrate_to_sqlite.exs` - Main migration script that copies data from PostgreSQL to SQLite
- `update_config_for_sqlite.exs` - Updates Elixir config files for SQLite adapter
- `update_config_for_sqlite_v2.exs` - Enhanced version of config update script
- `test_migration_analysis.exs` - Validation script for migration results

## Migration Guide

The complete migration guide is in `/MIGRATION_GUIDE.md` at the project root.

## Do Not Use

These scripts are for reference only. The codebase is now fully SQLite-based and PostgreSQL is no longer supported.
