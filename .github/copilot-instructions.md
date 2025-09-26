# Reencodarr AI Coding Instructions

## Project Overview
Reencodarr is an Elixir/Phoenix application for bulk video transcoding using the `ab-av1` CLI tool. It provides a web interface for analyzing, CRF searching, and encoding videos to AV1 with VMAF quality targeting, integrating with Sonarr/Radarr APIs for media management.

## Core Architecture

### Database: SQLite with Advanced Concurrency
**Key Change**: Migrated from PostgreSQL to SQLite with WAL mode for better deployment simplicity while maintaining concurrency.

- **Configuration**: All SQLite optimizations consolidated in `config/config.exs` with WAL mode, 256MB cache, 512MB memory mapping
- **Concurrency**: WAL mode enables simultaneous read/write operations (analyzer + sync can run concurrently)
- **Migration**: Use `scripts/migrate_to_sqlite.exs` for PostgreSQL→SQLite data migration

### Broadway Pipeline System
Three Broadway pipelines handle video processing with fault tolerance and observability:

- **Analyzer** (`lib/reencodarr/analyzer/broadway.ex`): Batches videos (up to 5) for single `mediainfo` command execution, rate-limited to 25 msg/sec
- **CRF Searcher** (`lib/reencodarr/crf_searcher/broadway.ex`): Single-concurrency pipeline that respects GenServer availability for VMAF quality targeting
- **Encoder** (`lib/reencodarr/encoder/broadway.ex`): Executes actual encoding with progress parsing and file operations

Key pattern: Each pipeline has a Producer that checks GenServer availability before dispatching work, preventing duplicate processing.

### Critical State Management
- **State Machine**: Videos use enum states (`:needs_analysis`, `:analyzed`, `:crf_searching`, `:crf_searched`, `:encoding`, `:encoded`, `:failed`) via `VideoStateMachine`
- **State Transitions**: Only valid transitions allowed via `VideoStateMachine.transition/3` - see `@valid_transitions` map
- **Test Environment**: Broadway-based workers and Analyzer supervisor disabled in `application.ex` to prevent process conflicts and DB ownership issues
- **Pipeline Coordination**: Producers call `dispatch_available()` after completion to notify other pipelines
- **Error Recovery**: Use `VideoStateMachine.mark_as_failed/1` instead of boolean flags

## Development Workflows

**Command Execution Note**: All commands should be executed directly without prefixing with `cd` to the project root. The working directory is always assumed to be the project root directory.

### Essential Commands
```bash
# Setup (no longer requires PostgreSQL)
mix setup                    # Full setup: deps, SQLite DB, assets

# Testing (ALWAYS run full test suite)
mix test                    # Uses manual sandbox mode - ALWAYS run complete suite, never individual tests

# Database
mix ecto.reset              # Drop/create/migrate/seed (SQLite)

# Code Quality (automated via git hooks)
mix setup_precommit         # Setup git hooks for credo + formatting
mix credo --strict          # Strict code analysis
mix format                  # Code formatting

# Debugging
# Visit /broadway-dashboard for pipeline monitoring
```

### Key Dependencies
- **Required Binaries**: `ab-av1`, `ffmpeg`, `mediainfo`
- **Database**: SQLite with WAL mode and optimized pragma settings (see `config/config.exs`)
- **External APIs**: Sonarr/Radarr via `CarReq` with circuit breaker pattern

## Project-Specific Patterns

### Database Configuration Pattern
**Critical**: SQLite optimizations are centralized in `config/config.exs` and must not be overridden in environment configs:

```elixir
# Base config applies to all environments
config :reencodarr, Reencodarr.Repo,
  pragma: [
    journal_mode: "WAL",       # Enable concurrent access
    busy_timeout: 120_000,     # 2-minute timeout for concurrent ops
    cache_size: -256_000,      # 256MB cache
    mmap_size: 536_870_912     # 512MB memory mapping
  ]
```

### Git Hooks & Code Quality
Pre-commit hooks automatically enforce code quality:
- **Setup**: `mix setup_precommit` configures git to use `.githooks/pre-commit`
- **Checks**: Credo strict mode, format validation, format migration detection
- **Stash Safety**: Unstaged changes are safely stashed during checks

### Broadway Pipeline Development
When adding new pipelines:
1. Create producer that checks GenServer availability (`crf_search_available?()` pattern)
2. Implement single concurrency to respect external tool limitations
3. Add telemetry events for dashboard updates
4. Update `application.ex` with test environment considerations

### Database Query Patterns
```elixir
# SQLite array operations for codec filtering (uses JSON functions)
fragment("EXISTS (SELECT 1 FROM json_each(?) WHERE json_each.value = ?)",
         v.video_codecs, "av1")

# State queries use enum states, not boolean flags
where: v.state not in [:encoded, :failed]
where: v.state == :needs_analysis
```

### Video State Management
- **State Machine**: `VideoStateMachine` enforces valid transitions between processing states
- **State Flow**: `needs_analysis → analyzed → crf_searching → crf_searched → encoding → encoded`
- **State Functions**: Use `VideoStateMachine.transition_to_*()` functions instead of direct updates
- **Error Handling**: `failed` state is terminal, use `VideoStateMachine.mark_as_failed/1` for error transitions

## When Integrating External Services

1. **Create Service Module**: Use `Reencodarr.Services.ApiClient` pattern in `lib/reencodarr/services/`
   ```elixir
   use CarReq,
     pool_timeout: 100,
     receive_timeout: 9_000,
     retry: :safe_transient,
     max_retries: 3,
     fuse_opts: {{:standard, 5, 30_000}, {:reset, 60_000}}
   ```

2. **Add Config Schema**: Create config entries in `configs` table with `service_type`, `url`, `api_key`

3. **Update Sync Module**: Add to `Reencodarr.Sync` with batch processing and error recovery

4. **Implement Webhooks**: Create controller in `lib/reencodarr_web/controllers/` for real-time updates

5. **Add Circuit Breaker**: Use fuse pattern to prevent cascade failures during API outages

#### Webhook Handling (`lib/reencodarr_web/controllers/sonarr_webhook_controller.ex`)
- **Event Types**: `Download`, `Rename`, `SeriesAdd`, `SeriesDelete` with specific handlers
- **File Upserts**: Automatic video creation via `Sync.upsert_video_from_file/2`
- **MediaInfo Conversion**: Service-specific data transformed to internal schema
- **Path Management**: Handles file moves/renames with video record updates

### Testing Considerations
- **Manual Sandbox**: Set in `test/test_helper.exs` for transaction isolation via `Ecto.Adapters.SQL.Sandbox.mode(Reencodarr.Repo, :manual)`
- **Disabled Services**: Broadway-based workers and Analyzer supervisor disabled in test to prevent process conflicts
- **Mocking**: Use `meck` for external command simulation
- **Fixtures**: Comprehensive test data generators in `test/support/fixtures.ex`

### File Operations
`FileOperations.move_file/4` handles cross-device moves with copy+delete fallback for EXDEV errors.

### Progress Parsing
Complex regex patterns in `@patterns` maps for ab-av1 output parsing:
```elixir
simple_vmaf: ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/
```

### Centralized Argument Building
`Reencodarr.Rules.build_args/4` handles command construction with context-aware filtering:
- `:crf_search` context includes `--min-crf`, `--max-crf` for search range
- `:encode` context filters out CRF range arguments, only uses single `--crf` value

## Key Directories
- `lib/reencodarr/{analyzer,crf_searcher,encoder}/` - Broadway pipelines
- `lib/reencodarr/services/` - External API clients
- `lib/reencodarr/ab_av1/` - Command execution and parsing
- `test/support/` - Shared test utilities and fixtures
- `scripts/` - Database migration and configuration update utilities
