# PostgreSQL to SQLite Migration Guide

This guide will help you migrate your Reencodarr data from PostgreSQL to SQLite.

## Prerequisites

1. Ensure your PostgreSQL database is running and accessible
2. Back up your PostgreSQL database first: `pg_dump reencodarr_dev > backup.sql`
3. Make sure you have the updated `mix.exs` with `ecto_sqlite3` dependency

## Migration Steps

### 1. Update Configuration Files

Run the configuration update script to switch your Elixir configuration to SQLite:

```bash
elixir scripts/update_config_for_sqlite.exs
```

This will update:
- `lib/reencodarr/repo.ex` - Change adapter to SQLite3
- `config/dev.exs` - SQLite development configuration
- `config/test.exs` - SQLite test configuration

### 2. Install SQLite Dependencies

```bash
mix deps.get
```

### 3. Run the Data Migration

The migration script will:
- Connect to your existing PostgreSQL database
- Create a new SQLite database with the correct schema
- Copy all data from PostgreSQL to SQLite, converting formats as needed
- Handle JSON fields, arrays, and enum types properly

```bash
elixir scripts/migrate_to_sqlite.exs
```

#### Environment Variables (optional)

You can customize the migration with these environment variables:

```bash
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres
export POSTGRES_HOST=localhost
export POSTGRES_DB=reencodarr_dev
export POSTGRES_PORT=5432
export SQLITE_DB=priv/reencodarr.db
```

### 4. Test the Migration

Start your application to test the migration:

```bash
mix phx.server
```

Visit `http://localhost:4000` and verify:
- All your videos are listed
- Libraries are present
- VMAF data is intact
- Configuration settings are preserved

### 5. Production Configuration (optional)

For production, update your `config/runtime.exs` to use the `DATABASE_PATH` environment variable:

```bash
export DATABASE_PATH=/app/data/reencodarr.db
```

## Data Type Conversions

The migration handles these PostgreSQL to SQLite conversions:

| PostgreSQL Type | SQLite Type | Notes |
|----------------|-------------|--------|
| `text[]` (arrays) | `TEXT` | Converted to JSON strings |
| `jsonb` | `TEXT` | Stored as JSON strings |
| Enums | `TEXT` | Converted to string values |
| `bigint` | `INTEGER` | Native SQLite integer |
| `boolean` | `BOOLEAN` | SQLite boolean support |

## Schema Differences

SQLite doesn't support all PostgreSQL features, but the migration handles this by:

1. **Arrays**: Converting to JSON text (e.g., `audio_codecs`)
2. **JSONB**: Converting to JSON text (e.g., `mediainfo`)
3. **Enums**: Converting to text strings (e.g., video `state`)
4. **Foreign Keys**: Preserved as constraints
5. **Indexes**: Recreated for performance

## Rollback Plan

If you need to rollback to PostgreSQL:

1. Restore your PostgreSQL backup: `psql reencodarr_dev < backup.sql`
2. Revert configuration changes:
   ```bash
   git checkout HEAD -- lib/reencodarr/repo.ex config/dev.exs config/test.exs
   ```
3. Update `mix.exs` to use `postgrex` instead of `ecto_sqlite3`
4. Run `mix deps.get`

## Troubleshooting

### Migration fails with "relation does not exist"
- Ensure PostgreSQL is running and accessible
- Check your database connection settings
- Verify the database name matches your development environment

### SQLite file permission errors
- Ensure the `priv/` directory is writable
- Check that no other processes are using the SQLite file

### Data validation errors
- Compare record counts: `SELECT COUNT(*) FROM table_name` in both databases
- Check for any custom data types that may need special handling

### Performance considerations
- SQLite uses WAL mode for better concurrency
- Cache size is optimized for development workloads
- Consider `PRAGMA optimize` for production databases

## File Locations

After migration, your data will be stored in:
- Development: `priv/reencodarr_dev.db`
- Test: `:memory:` (temporary)
- Production: `$DATABASE_PATH` (configurable)

The migration preserves all:
- Video records and metadata
- VMAF analysis results
- Library configurations
- Service API settings
- Failure tracking data
