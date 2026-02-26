# Reencodarr - AV1 Video Encoding Pipeline

## Project Overview

Reencodarr is an automated video encoding pipeline that analyzes media libraries, performs quality-targeted AV1 encoding using `ab-av1`, and manages the entire process through a Phoenix LiveView web interface.

**Tech Stack:**
- **Language:** Elixir 1.19 / OTP 28
- **Web Framework:** Phoenix 1.7 + LiveView
- **Database:** SQLite (via Ecto)
- **Encoding:** `ab-av1` wrapper for SVT-AV1 with VMAF quality targeting
- **Processing:** Broadway pipelines for concurrent video processing

**Host:** The app runs on host `tina` via `iex -S mix phx.server` (dev mode with automatic Erlang distribution enabled)

---

## Architecture

### Pipeline Flow

```
Sync → Analysis → CRF Search → Encoding → Post-Processing
```

1. **Sync**: Discovers video files from configured service libraries (Plex, Jellyfin, etc.)
2. **Analysis**: Extracts metadata (resolution, codecs, bitrate, HDR) via MediaInfo
3. **CRF Search**: Uses `ab-av1 crf-search` to find optimal CRF value for target VMAF quality
4. **Encoding**: Encodes video with chosen CRF using `ab-av1 encode`
5. **Post-Processing**: Moves encoded file, updates media server, cleans up

### Video State Machine

```
synced → analyzed → crf_searched → encoded → completed
         ↓          ↓               ↓
      analysis  crf_searching   encoding
```

Failed states can record failures in `video_failures` table and retry with backoff.

### Key Modules

| Module | Purpose |
|--------|---------|
| `Reencodarr.Sync` | Discovers videos from service APIs |
| `Reencodarr.Analyzer` | Extracts video metadata (facade for Broadway pipeline) |
| `Reencodarr.CrfSearcher` | Performs VMAF quality targeting (facade) |
| `Reencodarr.Encoder` | Encodes videos with chosen settings (facade) |
| `Reencodarr.AbAv1.CrfSearch` | GenServer wrapping `ab-av1 crf-search` Port |
| `Reencodarr.AbAv1.Encode` | GenServer wrapping `ab-av1 encode` Port |
| `Reencodarr.Rules` | Encoding argument builder (HDR, audio, resolution rules) |
| `Reencodarr.Media` | Core database queries for videos, VMAFs, failures |
| `Reencodarr.PipelineStateMachine` | State transitions and validation |

---

## Live System Diagnostics

The app automatically enables Erlang distribution on startup (node: `reencodarr@tina`, cookie: `reencodarr`). Use the `bin/rpc` wrapper to execute Elixir code on the live BEAM from bash.

### Quick Start

```bash
# System overview
bin/rpc 'Reencodarr.Diagnostics.status()'

# Inspect a specific video
bin/rpc 'Reencodarr.Diagnostics.video(123)'

# Find videos by path
bin/rpc 'Reencodarr.Diagnostics.find("Breaking Bad")'

# View recent failures
bin/rpc 'Reencodarr.Diagnostics.failures()'

# See what's in the queues
bin/rpc 'Reencodarr.Diagnostics.queues()'

# Check GenServer state
bin/rpc 'Reencodarr.Diagnostics.processes()'

# Find stuck videos
bin/rpc 'Reencodarr.Diagnostics.stuck()'

# Preview encoding args
bin/rpc 'Reencodarr.Diagnostics.video_args(123)'

# Full failure details
bin/rpc 'Reencodarr.Diagnostics.failure(456)'
```

### Command Reference

| Command | Description |
|---------|-------------|
| `status()` | System overview: pipeline status, queue counts, video states, failures |
| `video(id)` | Deep inspect: path, size, codecs, VMAFs, failures, encoding args |
| `find("fragment")` | Find videos by path substring (max 20 results) |
| `failures()` | Recent unresolved failures (max 20) |
| `failures(:crf_search)` | Filter failures by stage (`:analysis`, `:crf_search`, `:encoding`, `:post_process`) |
| `failure(id)` | Full failure detail including command + output from system_context |
| `queues()` | Next 10 items in each pipeline queue |
| `processes()` | Live GenServer state (CrfSearch, Encode, HealthCheck, cache, perf) |
| `stuck()` | Videos in `:crf_searching`/`:encoding` that may be orphaned |
| `video_args(id)` | Preview encoding args + VMAF target + rule breakdown |

### Example Debugging Workflows

**Investigate a stuck CRF search:**
```bash
# Check if CRF searcher is active
bin/rpc 'Reencodarr.Diagnostics.status()' | grep -A3 "CRF Searcher"

# See which video is being processed
bin/rpc 'Reencodarr.Diagnostics.processes()' | grep -A5 "CRF Search"

# Check for stuck videos
bin/rpc 'Reencodarr.Diagnostics.stuck()'
```

**Debug encoding failure:**
```bash
# List recent failures
bin/rpc 'Reencodarr.Diagnostics.failures(:encode)'

# Get full details (command + output)
bin/rpc 'Reencodarr.Diagnostics.failure(789)'
```

**Verify encoding args for a video:**
```bash
# See what args will be used
bin/rpc 'Reencodarr.Diagnostics.video_args(123)'

# Check individual rule contributions
bin/rpc 'Rules.hdr(Repo.get(Video, 123))'
```

### Environment Variables

- `REENCODARR_NODE`: Override node name (default: `reencodarr@$(hostname -s)`)
- `REENCODARR_COOKIE`: Override cookie (default: `reencodarr`)

---

## Development

### Running the App

```bash
# Start Phoenix server (distribution auto-enabled)
iex -S mix phx.server

# Run tests
mix test

# Format code
mix format

# Check for warnings
mix compile --warnings-as-errors
```

### IEx Helpers

The `.iex.exs` defines helper functions available in the console:

```elixir
pipelines_status()  # All pipeline status
queue_counts()      # Queue counts
next_items()        # Next items in queues
start_all()         # Resume CRF searcher
pause_all()         # Pause CRF searcher
video_states()      # Video state counts
find_video("path")  # Find videos by path
debug_video(123)    # Debug specific video
```

---

## Database

### Tables

**videos**: Core video records
- Columns: `id`, `path`, `size`, `state`, `width`, `height`, `bitrate`, `duration`, `fps`, `video_codecs`, `audio_codecs`, `container_format`, `hdr`, `service_name`, `series_name`, `library_id`
- State enum: `:synced`, `:analyzed`, `:crf_searched`, `:encoded`, `:completed`, `:analysis`, `:crf_searching`, `:encoding`

**vmafs**: CRF search results
- Columns: `id`, `video_id`, `crf`, `vmaf_score`, `vmaf_percentile`, `predicted_filesize`, `chosen`
- One video can have multiple VMAF results; one is marked `chosen: true`

**video_failures**: Error tracking
- Columns: `id`, `video_id`, `failure_stage`, `failure_category`, `failure_code`, `failure_message`, `system_context` (map with `command`, `full_output`), `retry_count`, `resolved`, `resolved_at`
- Stage enum: `:analysis`, `:crf_search`, `:encode`
- Category enum: `:timeout`, `:command_error`, `:validation_error`, `:file_error`, `:unknown`

**configs**: Service configurations (Plex, Jellyfin API keys)
- Columns: `id`, `service_name`, `settings` (map)

**libraries**: Media library paths
- Columns: `id`, `name`, `path`, `config_id`

### Key Queries

```elixir
# Videos needing CRF search
from v in Video, where: v.state == :analyzed

# Unresolved failures for a video
from f in VideoFailure, where: f.video_id == ^id and f.resolved == false

# Chosen VMAF for a video
from v in Vmaf, where: v.video_id == ^id and v.chosen == true
```

---

## Encoding Rules

VMAF target is size-based (see `Rules.vmaf_target/1`):
- `>60 GiB` → 91 VMAF
- `>40 GiB` → 92 VMAF
- `>25 GiB` → 94 VMAF
- `≤25 GiB` → 95 VMAF

Args are built by `Rules.build_args(video, context)`:
- **HDR Rule**: `--pix-format yuv420p10le` for HDR content
- **Resolution Rule**: `--preset 4` for ≥1080p, `--preset 6` for <1080p
- **Video Rule**: `--svt av1`, `--video-params tune=0`
- **Grain Rule**: `--video-params film-grain=X` for vintage content
- **Audio Rule** (encode only): `--audio-params ac=2:b=128k:c=libopus` + downmix logic

---

## Troubleshooting

**CRF search never starts:**
- Check: `bin/rpc 'Reencodarr.Diagnostics.queues()'` (is queue empty?)
- Check: `bin/rpc 'CrfSearcher.running?()'` (is pipeline paused?)

**Encoding stuck:**
- Check: `bin/rpc 'Reencodarr.Diagnostics.processes()'` (health check state)
- Check: `bin/rpc 'Reencodarr.Diagnostics.stuck()'` (orphaned videos?)

**Failures piling up:**
- Check: `bin/rpc 'Reencodarr.Diagnostics.failures()'` (what categories?)
- Check: `bin/rpc 'Reencodarr.Diagnostics.failure(ID)'` (full context)

**Database locked:**
- SQLite only supports one writer. Check for concurrent writes or stuck transactions.

---

## Notes for Claude

- Always use `bin/rpc` to inspect live state—never guess what the BEAM is doing
- Failures have `system_context` with full command + output; always read it before debugging
- The CRF search and encode GenServers are single-worker (one video at a time)
- Videos can be in "processing" states (`:analysis`, `:crf_searching`, `:encoding`) if actively being worked on, or "completed" states (`:analyzed`, `:crf_searched`, `:encoded`) if work finished
- Always check `stuck()` if videos seem to be in processing states for too long
- The Broadway pipelines are always "running" but may not be "actively running" if no work available
- Use `video_args(id)` to preview what encoding args will be used before debugging arg-related issues
