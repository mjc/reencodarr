# Reencodarr AI Coding Instructions

## Project Overview
Reencodarr is an Elixir/Phoenix web application for bulk video transcoding using the `ab-av1` Rust CLI tool. It provides a web interface for analyzing, CRF searching, and encoding videos to AV1 with VMAF quality targeting. The app integrates with Sonarr/Radarr for media management.

## Core Architecture & Data Flow

### Broadway Pipeline System
The application uses Broadway for robust, fault-tolerant video processing with three main pipelines:

1. **Analyzer Pipeline** (`lib/reencodarr/analyzer/broadway.ex`):
   - Batches up to 5 videos for single `mediainfo` command execution (massive performance gain)
   - Rate limited to 25 messages/second to prevent system overload
   - Extracts metadata: codecs, bitrate, resolution, audio channels, HDR info
   - Updates videos with `failed: true` flag on processing errors
   - Emits telemetry for dashboard updates via Phoenix PubSub

2. **CRF Searcher** (`lib/reencodarr/crf_searcher/`):
   - Uses complex regex patterns in `lib/reencodarr/ab_av1/crf_search.ex` to parse ab-av1 output
   - Tracks VMAF scores, encoding progress, and optimal CRF values
   - Stores results in `vmafs` table with size predictions and quality metrics
   - Pattern: `@patterns` map with named regex captures for different output formats

3. **Encoder Pipeline** (`lib/reencodarr/encoder/`):
   - Executes actual video encoding using ab-av1 with parsed parameters
   - Progress parsing via `Reencodarr.ProgressParser` with FPS/ETA extraction
   - Post-processing through `Reencodarr.PostProcessor` for file moves and DB updates

### Critical State Management
- **Test Environment**: Analyzer.Supervisor disabled in `application.ex` to prevent DB ownership conflicts
- **GenServer Pattern**: Queue managers track pipeline state (`Reencodarr.Analyzer.QueueManager`)
- **Cross-Device File Operations**: `FileOperations.move_file/4` handles EXDEV errors with copy+delete fallback
- **Memory Optimization**: Dashboard stores only processed data, not raw state (70% memory reduction)

### Database Query Patterns
```elixir
# Video filtering with PostgreSQL array operations
fragment("EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))", 
         v.audio_codecs, "%opus%")

# CRF search candidates (see Media.get_videos_for_crf_search/1)
where: is_nil(m.id) and v.reencoded == false and v.failed == false
```

## External Service Integration Patterns

### Sonarr/Radarr API Integration
- **HTTP Client**: Uses `CarReq` with circuit breaker pattern (5 failures/30s window, 60s reset)
- **Retry Strategy**: `:safe_transient` with 3 max retries for transient failures
- **Authentication**: API key via `X-Api-Key` header from config database
- **Sync Workflow**: `Reencodarr.Sync` GenServer coordinates polling and data fetching
- **Rate Limiting**: 1 concurrent operation for series refresh/rename operations

### ab-av1 Command Integration
- **Progress Parsing**: Complex regex patterns in `@patterns` map for different output formats:
  ```elixir
  simple_vmaf: ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/
  ```
- **Error Handling**: Exit code tracking with video `failed: true` marking
- **Parameter Generation**: `Reencodarr.Rules` applies encoding rules based on video metadata
- **Output Parsing**: Structured extraction of CRF values, VMAF scores, file sizes

### MediaInfo Batch Processing
- **Optimization**: Single command for multiple files vs individual calls (10x performance gain)
- **Track Extraction**: Separates General/Video/Audio tracks with safe fallbacks
- **Codec Mapping**: `CodecMapper.format_commercial_if_any/1` for normalized codec names
- **Error Recovery**: Graceful degradation on malformed MediaInfo JSON responses

## Development Workflows & Critical Commands

### Environment Setup
```bash
mix setup                    # deps.get + ecto.setup + assets.setup + assets.build
make docker-compose-up       # PostgreSQL via Docker (required for development)
iex -S mix phx.server       # Interactive development with live reloading
```

### Database Operations
```bash
mix ecto.reset              # Drops + creates + migrates + seeds
mix test                    # Uses :manual sandbox mode (see test_helper.exs)
```

### Debugging Broadway Pipelines
- **Dashboard**: `/broadway-dashboard` for live pipeline monitoring
- **Telemetry**: `Reencodarr.Telemetry` events for state tracking
- **Queue Inspection**: `Reencodarr.AbAv1.queue_length/0` for GenServer message counts

## Project-Specific Patterns & Conventions

### Error Handling Strategy
- **Videos**: `failed: true` flag prevents infinite retry loops
- **Broadway**: Automatic retries with exponential backoff built-in
- **File Operations**: Cross-device move detection with copy+delete fallback
- **External APIs**: Circuit breaker pattern prevents cascade failures

### Memory Management (Dashboard)
- **Optimization**: Dashboard stores processed data only (not raw state)
- **Telemetry Filtering**: Only emit events on >5% progress changes
- **Component Reduction**: Inline functions vs LiveComponents (80% reduction)
- **Timer Management**: 5-second intervals for stardate updates

### Testing Environment Considerations
- **Analyzer Disabled**: Prevents database ownership conflicts in parallel tests
- **Sandbox Mode**: Manual mode in `test_helper.exs` for transaction isolation
- **Mock Patterns**: Use `meck` for external command mocking

### Configuration Patterns
- **Runtime Config**: Database-driven config in `configs` table vs compile-time
- **Pool Sizes**: PostgreSQL pool_size: 50 for development concurrency
- **Rate Limiting**: Broadway 25 msg/sec prevents system overload during analysis
- **Asset Pipeline**: Tailwind + ESBuild with file watching in development

## Critical File Patterns & Code Structure

### When Adding New Processing Pipelines:
1. Create supervisor in `lib/reencodarr/{name}/supervisor.ex`
2. Implement Broadway module with rate limiting configuration
3. Add producer/consumer pattern with telemetry events
4. Update `application.ex` worker_children (test environment considerations)

### When Modifying Video Processing Logic:
1. Update schema in `lib/reencodarr/media/video.ex` for new fields
2. Create migration with proper indexes for query patterns
3. Modify MediaInfo parsing in `media_info.ex` for metadata extraction
4. Update `get_videos_for_*` queries with array fragment patterns

### When Integrating External Services:
1. Create service module in `lib/reencodarr/services/` with CarReq client
2. Add config schema with API credentials in database
3. Update `Reencodarr.Sync` for polling coordination
4. Implement circuit breaker and retry patterns for reliability

### LiveView Real-time Updates:
- **PubSub Events**: Phoenix.PubSub.broadcast for cross-process communication
- **Telemetry Integration**: `:telemetry.attach_many/4` for event streaming
- **Memory Optimization**: Use presenters to transform data before assigns
- **Component Structure**: Prefer function components over LiveComponents for performance

Remember: App requires PostgreSQL, ab-av1, FFmpeg, and MediaInfo binaries. Test environment uses sandbox mode and disables certain supervisors to prevent database conflicts.
