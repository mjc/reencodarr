# Reencodarr AI Coding Instructions

## Project Overview
Reencodarr is an Elixir/Phoenix application for bulk video transcoding using the `ab-av1` CLI tool. It provides a web interface for analyzing, CRF searching, and encoding videos to AV1 with VMAF quality targeting, integrating with Sonarr/Radarr APIs for media management.

## Core Architecture

### Broadway Pipeline System
Three Broadway pipelines handle video processing with fault tolerance and observability:

- **Analyzer** (`lib/reencodarr/analyzer/broadway.ex`): Batches videos (up to 5) for single `mediainfo` command execution, rate-limited to 25 msg/sec
- **CRF Searcher** (`lib/reencodarr/crf_searcher/broadway.ex`): Single-concurrency pipeline that respects GenServer availability for VMAF quality targeting
- **Encoder** (`lib/reencodarr/encoder/broadway.ex`): Executes actual encoding with progress parsing and file operations

Key pattern: Each pipeline has a Producer that checks GenServer availability before dispatching work, preventing duplicate processing.

### Critical State Management
- **State Machine**: Videos use enum states (`:needs_analysis`, `:analyzed`, `:crf_searching`, `:crf_searched`, `:encoding`, `:encoded`, `:failed`) via `VideoStateMachine`
- **State Transitions**: Only valid transitions allowed via `VideoStateMachine.transition/3` - see `@valid_transitions` map
- **Test Environment**: Analyzer supervisor disabled in `application.ex` to prevent DB ownership conflicts
- **Pipeline Coordination**: Producers call `dispatch_available()` after completion to notify other pipelines
- **Error Recovery**: Use `VideoStateMachine.mark_as_failed/1` instead of boolean flags

## Development Workflows

### Essential Commands
```bash
# Setup (requires PostgreSQL)
mix setup                    # Full setup: deps, DB, assets
make docker-compose-up       # Start PostgreSQL container
iex -S mix phx.server       # Development with live reload

# Database
mix ecto.reset              # Drop/create/migrate/seed
mix test                    # Uses manual sandbox mode

# Debugging
# Visit /broadway-dashboard for pipeline monitoring
```

### Key Dependencies
- **Required Binaries**: `ab-av1`, `ffmpeg`, `mediainfo`
- **Database**: PostgreSQL with pool_size: 50 for dev concurrency
- **External APIs**: Sonarr/Radarr via `CarReq` with circuit breaker pattern

## Project-Specific Patterns

### Broadway Pipeline Development
When adding new pipelines:
1. Create producer that checks GenServer availability (`crf_search_available?()` pattern)
2. Implement single concurrency to respect external tool limitations
3. Add telemetry events for dashboard updates
4. Update `application.ex` with test environment considerations

### Database Query Patterns
```elixir
# Array operations for codec filtering
fragment("EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))", 
         v.audio_codecs, "%opus%")

# State queries use enum states, not boolean flags
where: v.state not in [:encoded, :failed]
where: v.state == :needs_analysis
```

### Video State Management
- **State Machine**: `VideoStateMachine` enforces valid transitions between processing states
- **State Flow**: `needs_analysis → analyzed → crf_searching → crf_searched → encoding → encoded`
- **State Functions**: Use `VideoStateMachine.transition_to_*()` functions instead of direct updates
- **Error Handling**: `failed` state is terminal, use `mark_as_failed/1` for error transitions

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
- **Manual Sandbox**: Set in `test/test_helper.exs` for transaction isolation
- **Disabled Services**: Analyzer supervisor disabled in test to prevent conflicts
- **Mocking**: Use `meck` for external command simulation
- **Fixtures**: Comprehensive test data generators in `test/support/fixtures.ex`

### File Operations
`FileOperations.move_file/4` handles cross-device moves with copy+delete fallback for EXDEV errors.

### Progress Parsing
Complex regex patterns in `@patterns` maps for ab-av1 output parsing:
```elixir
simple_vmaf: ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/
```

## Key Directories
- `lib/reencodarr/{analyzer,crf_searcher,encoder}/` - Broadway pipelines
- `lib/reencodarr/services/` - External API clients
- `lib/reencodarr/ab_av1/` - Command execution and parsing
- `test/support/` - Shared test utilities and fixtures
