# Reencodarr

An Elixir/Phoenix web application for bulk video transcoding using the `ab-av1` CLI tool. Features a web interface for analyzing, CRF searching, and encoding videos to AV1 with VMAF quality targeting, with optional integration to Sonarr/Radarr APIs for media management.

## Features

- **Video Analysis**: Automated analysis of video files using MediaInfo
- **CRF Search**: VMAF-based quality targeting to find optimal encoding settings
- **Bulk Encoding**: Queue-based encoding system with progress tracking
- **Media Server Integration**: Sonarr/Radarr webhook support for automatic processing
- **Real-time Dashboard**: Live updates via WebSockets with queue monitoring
- **Failure Tracking**: Comprehensive error reporting and pattern analysis
- **SQLite Database**: Simple deployment with WAL mode for concurrent operations

## Quick Start

### Development Setup

1. **Install Dependencies**:
   - Elixir/Erlang (via asdf, mise, or your package manager)
   - Required binaries: `ab-av1`, `ffmpeg`, `mediainfo`

2. **Setup Application**:
   ```bash
   git clone <repository>
   cd reencodarr
   mix setup  # Installs deps, creates SQLite DB, compiles assets
   ```

3. **Start Development Server**:
   ```bash
   mix phx.server
   ```

4. **Access Application**:
   - HTTP: [`localhost:4000`](http://localhost:4000)
   - HTTPS: [`localhost:4001`](https://localhost:4001) (self-signed certificate)
   - Accept the browser security warning for the self-signed certificate

### WebSocket Support

For optimal real-time updates, use HTTPS in development. The application automatically generates self-signed certificates and configures both HTTP (port 4000) and HTTPS (port 4001). Modern browsers require secure connections for WebSocket functionality.

### Production Deployment

#### SSL Certificate Setup (Local Network Only)

**⚠️ WARNING: The generated certificate is ONLY for local network access. DO NOT use for public internet deployment!**

1. **Generate Production Certificate**:
   ```bash
   ./scripts/gen_prod_cert.sh
   ```

2. **Enable SSL in Production**:
   ```bash
   export REENCODARR_ENABLE_SSL="true"
   export REENCODARR_SSL_CERT_PATH="priv/cert/prod_cert.pem"
   export REENCODARR_SSL_KEY_PATH="priv/cert/prod_key.pem"
   export HTTPS_PORT="4001"
   ```

3. **For Public Internet Deployment**:
   Use proper certificates from:
   - [Let's Encrypt](https://letsencrypt.org) (free)
   - Your domain provider
   - A commercial certificate authority

#### Environment Variables

```bash
# Database
export DATABASE_PATH="priv/reencodarr_prod.db"
export DATABASE_POOL_SIZE="20"

# Phoenix
export SECRET_KEY_BASE="<generate with: mix phx.gen.secret>"
export PHX_HOST="your-domain.com"
export PORT="4000"
export PHX_SERVER="true"

# SSL (optional, for local network only)
export REENCODARR_ENABLE_SSL="true"
export REENCODARR_SSL_CERT_PATH="priv/cert/prod_cert.pem"
export REENCODARR_SSL_KEY_PATH="priv/cert/prod_key.pem"
export HTTPS_PORT="4001"
```

To start your Reencodarr server for development:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) or [`localhost:4001`](https://localhost:4001) from your browser.

## Project Status

  - [x] Video Analysis Pipeline
  - [x] CRF Search with VMAF Targeting
  - [x] Bulk Video Encoding
  - [x] SQLite Database (migrated from PostgreSQL)
  - [x] Real-time Dashboard with WebSockets
  - [x] Sonarr Integration
  - [x] Radarr Integration
  - [x] Manual Scanning and Queue Management
  - [x] Comprehensive Failure Tracking
  - [ ] Docker Container Image
  - [ ] Application Clustering
  - [ ] Flexible Format Selection Rules
  - [ ] Hardware Acceleration Configuration UI
  - [ ] Setup Wizard
  - [ ] User Authentication (⚠️ **Do not expose to public internet without authentication**)
  - [ ] Visual Quality Comparison UI

## Architecture

### Database: SQLite with WAL Mode
- **Simple Deployment**: Single file database with no external dependencies
- **Concurrent Operations**: WAL mode enables simultaneous read/write operations
- **Optimized Configuration**: 256MB cache, 512MB memory mapping for performance
- **Migration Support**: Scripts available for PostgreSQL→SQLite migration

### Broadway Pipeline System
Three fault-tolerant processing pipelines handle video operations:

- **Analyzer**: Batched video analysis (up to 5 videos per MediaInfo call)
- **CRF Searcher**: Single-concurrency pipeline for VMAF quality targeting
- **Encoder**: Actual video encoding with progress monitoring

### State Management
Videos use a state machine with transitions: `needs_analysis → analyzed → crf_searching → crf_searched → encoding → encoded/failed`

## Failure Tracking & Monitoring

Reencodarr includes a comprehensive failure tracking system that captures detailed information about processing failures across the entire video encoding pipeline. This helps identify systemic issues, track resolution progress, and make data-driven improvements.

### Features

- **Granular Failure Classification**: Failures are categorized by processing stage (analysis, CRF search, encoding, post-processing) and specific failure types
- **Rich Context Capture**: System information, retry counts, error messages, and diagnostic data
- **Pattern Recognition**: Automatic identification of common failure patterns with actionable recommendations
- **Resolution Tracking**: Mark failures as resolved and track improvement over time
- **Critical Failure Detection**: Immediate identification of system-level issues requiring urgent attention

### Usage

#### Generate Failure Reports

```bash
# Basic report for last 7 days
mix reencodarr.failure_report

# Extended report with more patterns
mix reencodarr.failure_report --days 14 --limit 20

# JSON output for external tools
mix reencodarr.failure_report --format json
```

#### Programmatic Access

```elixir
# Comprehensive failure analysis
report = Reencodarr.FailureReporting.generate_failure_report(days_back: 7, limit: 10)

# Quick dashboard overview
overview = Reencodarr.FailureReporting.get_failure_overview(days_back: 1)

# Critical failures requiring immediate attention
critical = Reencodarr.FailureReporting.get_critical_failures(days_back: 1)
```

### Failure Categories

#### Analysis Stage
- **File Access**: Permission denied, file not found, network issues
- **MediaInfo Parsing**: Invalid output, command failures, malformed metadata
- **Validation**: Schema validation failures, missing required fields

#### CRF Search Stage
- **VMAF Calculation**: Scoring algorithm failures, corrupted samples
- **CRF Optimization**: Failed to find suitable quality/bitrate balance
- **Size Limits**: Predicted output exceeds configured size limits
- **Preset Retry**: Fallback encoding preset failures

#### Encoding Stage
- **Process Failure**: ab-av1 crashes, non-zero exit codes
- **Resource Exhaustion**: Out of memory, disk space, CPU overload
- **Codec Issues**: Unsupported formats, compatibility problems
- **Timeout**: Process exceeds configured time limits

#### Post-Processing Stage
- **File Operations**: Move, copy, rename failures across devices
- **Sync Integration**: Sonarr/Radarr API communication errors
- **Cleanup**: Temporary file removal issues

### Report Output Example

```
=== Video Processing Failure Report ===
Period: Last 7 days

Summary:
  Total Failures: 23
  Resolved: 8
  Unresolved: 15
  Resolution Rate: 34.8%

Failures by Stage:
  encoding: 12 total (8 unresolved)
  analysis: 7 total (5 unresolved)
  crf_search: 4 total (2 unresolved)

Most Common Failure Patterns:
  encoding/resource_exhaustion (EXIT_137): 8 occurrences
    Sample: Process killed by system (likely OOM)
  analysis/file_access (FILE_ACCESS): 5 occurrences
    Sample: File access failed: Permission denied

Recommendations:
  [HIGH] Resource Exhaustion Issues
    8 failures indicate system resource problems
    Action: Monitor memory usage and consider increasing system resources
```

### Database Schema

The failure tracking system uses a dedicated `video_failures` table with the following structure:

- `video_id`: Reference to the failed video
- `failure_stage`: Processing stage where failure occurred
- `failure_category`: Specific type of failure
- `failure_code`: Machine-readable error code
- `failure_message`: Human-readable error description
- `system_context`: JSON field with diagnostic information
- `retry_count`: Number of retry attempts
- `resolved`: Whether the failure has been resolved
- `resolved_at`: Timestamp of resolution

### Integration

The failure tracking system is automatically integrated into all video processing pipelines:

- **Broadway Pipelines**: Automatic failure capture in analysis, CRF search, and encoding stages
- **File Operations**: Cross-device move failures, permission issues
- **External Services**: Sonarr/Radarr sync failures and API errors
- **System Resources**: Memory exhaustion, disk space, timeout detection

## Learn more

  * `ab-av1` GitHub: https://github.com/alexheretic/ab-av1
  * `ab-av1` crates.io: https://crates.io/crates/ab-av1
  * FFmpeg: https://ffmpeg.org/
  * SVT-AV1: https://gitlab.com/AOMediaCodec/SVT-AV1
  * x265: https://bitbucket.org/multicoreware/x265_git/src/master/
  * VMAF: https://github.com/Netflix/vmaf
  * Why VMAF: https://netflixtechblog.com/toward-a-better-quality-metric-1b5bafa0b02d
