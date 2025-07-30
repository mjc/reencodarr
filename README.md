# Reencodarr

This is a WIP frontend for using the Rust CLI tool `ab-av1` to do bulk conversions based on time or space efficiency. It requires PostgreSQL for now but will not need it in the future.

It currently doesn't actually encode but that's next on the todo list.

To start your Reencodarr server for development:

  * make sure you have postgres set up and running locally with unix auth.
  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Planned Items

  - [x] Encoding
  - [ ] Docker image
  - [ ] Clustering
  - [ ] Remove PostgreSQL dependency
  - [ ] Flexible format selection rules (including toggling different kinds of hwaccel. cuda decoding is always on currently)
  - [ ] Automatic syncing
  - [x] Syncing button for Sonarr
  - [ ] Setup wizard
  - [ ] Radarr integration
  - [x] Manual syncing and scanning
  - [ ] Authentication. Don't run this thing on the public internet. You've been warned.
  - [ ] a UI for comparing results

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
