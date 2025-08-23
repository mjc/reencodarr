# Reencodarr AI Coding Instructions

## Project Overview
Reencodarr is an Elixir/Phoenix application for bulk video transcoding using the `ab-av1` CLI tool. It provides a web interface for analyzing, CRF searching, and encoding videos to AV1 with VMAF quality targeting, integrating with Sonarr/Radarr APIs for media management.

**Recent Architecture**: All ab-av1 output processing has been centralized in `Reencodarr.AbAv1.ProgressParser` with context-aware dispatching to separate encoding and CRF search handlers. This provides unified telemetry emission and simplified testing.

## Core Architecture

### Broadway Pipeline System
Three Broadway pipelines handle video processing with fault tolerance and observability:

- **Analyzer** (`lib/reencodarr/analyzer/broadway.ex`): Batches videos (up to 5) for single `mediainfo` command execution, rate-limited to 25 msg/sec
- **CRF Searcher** (`lib/reencodarr/crf_searcher/broadway.ex`): Single-concurrency pipeline that respects GenServer availability for VMAF quality targeting
- **Encoder** (`lib/reencodarr/encoder/broadway.ex`): Executes actual encoding with progress parsing and file operations

Key pattern: Each pipeline has a Producer that checks GenServer availability before dispatching work, preventing duplicate processing.

### Supervision Tree Architecture
```
Application
├── ReencodarrWeb.Endpoint (Phoenix)
├── Reencodarr.Repo (Database)
├── Phoenix.PubSub (Event Bus)
├── TaskSupervisor
├── TelemetryReporter (Dashboard State)
└── WorkerSupervisor
    ├── ManualScanner (GenServer)
    ├── AbAv1 (Supervisor for CRF/Encode workers)
    ├── Sync (External API integration)
    ├── Analyzer.Supervisor
    │   ├── QueueManager (GenServer for queue state)
    │   └── Broadway Pipeline
    ├── CrfSearcher.Supervisor
    │   └── Broadway Pipeline
    └── Encoder.Supervisor
        └── Broadway Pipeline
```

### Producer State Management Pattern
Each Broadway producer implements a consistent state machine:
- **States**: `:paused`, `:running`, `:processing`, `:pausing`
- **Demand Flow**: Accumulates demand, dispatches when conditions met
- **Availability Checking**: Queries underlying GenServer before dispatch
- **Telemetry**: Periodic queue state emission (every 5s)
- **PubSub Integration**: Subscribes to completion events for pipeline coordination

### Critical State Management
- **State Machine**: Videos use enum states (`:needs_analysis`, `:analyzed`, `:crf_searching`, `:crf_searched`, `:encoding`, `:encoded`, `:failed`) via `VideoStateMachine`
- **State Transitions**: Only valid transitions allowed via `VideoStateMachine.transition/3` - see `@valid_transitions` map
- **Test Environment**: Analyzer supervisor disabled in `application.ex` to prevent DB ownership conflicts
- **Pipeline Coordination**: Producers call `dispatch_available()` after completion to notify other pipelines
- **Error Recovery**: Use `VideoStateMachine.mark_as_failed/1` instead of boolean flags

### Event-Driven Telemetry Architecture
Real-time dashboard updates without polling through a comprehensive telemetry pipeline:

#### Complete Telemetry Flow Architecture
```
ab-av1 Process → Port → ProgressParser → Telemetry.emit_*() → :telemetry.execute()
                                                                      ↓
Broadway Producers → :telemetry.execute() → TelemetryEventHandler → TelemetryReporter
                                                                           ↓
                                           Phoenix.PubSub → LiveView Dashboard
```

#### Telemetry Data Sources
1. **ab-av1 Output Processing** (`ProgressParser`)
   - Encoding progress: `[:reencodarr, :encoder, :progress]`
   - Encoding lifecycle: `[:reencodarr, :encoder, :started/:completed/:failed]`
   - CRF search progress: `[:reencodarr, :crf_search, :progress/:started/:completed]`

2. **Broadway Producer State** (Every 5 seconds)
   - Queue changes: `[:reencodarr, :analyzer/:crf_searcher/:encoder, :queue_changed]`
   - Pipeline status: `[:reencodarr, :analyzer/:encoder/:crf_search, :started/:paused]`

3. **Media Operations**
   - Database events: `[:reencodarr, :media, :video_upserted/:vmaf_upserted]`

#### TelemetryReporter (Central State Manager) (`lib/reencodarr/telemetry_reporter.ex`)
Acts as the central hub for telemetry processing with advanced optimizations:

**Architecture**:
- **Event-Driven**: Pure reactive updates via Broadway producer telemetry (no polling)
- **State Filtering**: Only emits telemetry on significant changes (>1% progress deltas)
- **Memory Optimization**: Process dictionary caching for state comparison
- **Minimal Payloads**: Excludes inactive progress data (50-70% reduction)

**State Management**:
```elixir
@impl true
def init(_opts) do
  attach_telemetry_handlers()
  initial_state = %DashboardState{analyzing: false, crf_searching: false, encoding: false}
  send(self(), :load_initial_state)
  {:ok, initial_state}
end
```

**Event Processing**: Delegates to `TelemetryEventHandler` for clean separation:
```elixir
def handle_event(event_name, measurements, metadata, _config) do
  config = %{reporter_pid: __MODULE__}
  Reencodarr.TelemetryEventHandler.handle_event(event_name, measurements, metadata, config)
end
```

#### TelemetryEventHandler (`lib/reencodarr/telemetry_event_handler.ex`)
Centralized routing of telemetry events to appropriate TelemetryReporter actions:

**Event Categories**:
- **Encoder Events**: `started`, `progress`, `completed`, `failed`, `paused`
- **CRF Search Events**: `started`, `progress`, `completed`, `paused`  
- **Analyzer Events**: `started`, `paused`
- **Queue Events**: `queue_changed` (triggers immediate stats refresh)
- **Sync Events**: External API synchronization status

**Handler Pattern**:
```elixir
def handle_event([:reencodarr, :encoder, :progress], measurements, _metadata, %{reporter_pid: pid}) do
  GenServer.cast(pid, {:update_encoding_progress, measurements})
end
```

#### Dashboard State Updates & PubSub Bridge
TelemetryReporter consolidates all telemetry into dashboard state and publishes to LiveView:

**Significance Filtering**:
```elixir
defp emit_state_update_and_return(%DashboardState{} = new_state) do
  old_state = Process.get(:last_emitted_state, DashboardState.initial())
  is_significant = DashboardState.significant_change?(old_state, new_state)
  
  if is_significant do
    minimal_state = %{
      stats: new_state.stats,
      encoding: new_state.encoding,
      encoding_progress: if(new_state.encoding, do: new_state.encoding_progress, else: %EncodingProgress{}),
      # ... other essential state
    }
    
    :telemetry.execute([:reencodarr, :dashboard, :state_updated], %{}, %{state: minimal_state})
    Process.put(:last_emitted_state, new_state)
  end
  
  new_state
end
```

#### LiveView Dashboard Integration (`lib/reencodarr_web/live/dashboard_live.ex`)
Receives telemetry-driven state updates for real-time UI updates:

**Telemetry Attachment**:
```elixir
defp setup_telemetry(socket) do
  if connected?(socket) do
    :telemetry.attach_many(
      "dashboard-#{inspect(self())}",
      [[:reencodarr, :dashboard, :state_updated]],
      &__MODULE__.handle_telemetry_event/4,
      %{live_view_pid: self()}
    )
  end
  socket
end
```

**Real-time Updates**:
```elixir
def handle_telemetry_event([:reencodarr, :dashboard, :state_updated], _measurements, %{state: state}, %{live_view_pid: pid}) do
  send(pid, {:telemetry_event, state})
end

def handle_info({:telemetry_event, state}, socket) do
  dashboard_data = Presenter.present(state, socket.assigns.timezone)
  {:noreply, assign(socket, :dashboard_data, dashboard_data)}
end
```

#### Performance Optimizations

**Memory Management**:
- Process dictionary for state comparison (no extra GenServer state)
- Excludes inactive progress data from telemetry payloads
- Direct database queries for initial state

**Update Efficiency**:
- 1% progress change threshold prevents excessive UI updates
- Significance detection avoids unnecessary PubSub messages
- Minimal telemetry payloads reduce message size by 50-70%

**Event Deduplication**:
- Last state caching prevents duplicate dashboard updates
- Queue change events trigger immediate stats refresh with current data
- Producer state changes only emit when transitioning between states

#### Telemetry Events Reference
- **Queue Changes**: `[:reencodarr, :analyzer/:crf_searcher/:encoder, :queue_changed]`
- **Progress Updates**: `[:reencodarr, :encoder/:crf_search, :progress]`
- **State Changes**: `[:reencodarr, :analyzer/:encoder/:crf_search, :started/:paused]`
- **Media Events**: `[:reencodarr, :media, :video_upserted/:vmaf_upserted]`
- **Dashboard Updates**: `[:reencodarr, :dashboard, :state_updated]`

#### TelemetryReporter (Central State Manager)
- **Event-Driven**: Pure reactive updates via Broadway producer telemetry
- **State Filtering**: Only emits telemetry on significant changes (>1% progress deltas)
- **Memory Optimization**: Process dictionary caching for state comparison
- **Minimal Payloads**: Excludes inactive progress data (50-70% reduction)

#### PubSub Event Flow
```
Broadway Producer → :telemetry.execute() → TelemetryEventHandler → TelemetryReporter
                                                                   ↓
LiveView ← Phoenix.PubSub ← [:reencodarr, :dashboard, :state_updated]
```

#### Telemetry Events
- **Queue Changes**: `[:reencodarr, :analyzer/:crf_searcher/:encoder, :queue_changed]`
- **Progress Updates**: `[:reencodarr, :encoder/:crf_search, :progress]`
- **State Changes**: `[:reencodarr, :analyzer/:encoder/:crf_search, :started/:paused]`
- **Media Events**: `[:reencodarr, :media, :video_upserted/:vmaf_upserted]`

### Database Architecture
- **Video State Enum**: PostgreSQL enum type with indexed state transitions
- **Conflict Resolution**: Upsert operations with `conflict_except` field filtering
- **Query Optimization**: State-based indexes for efficient queue queries
- **Pool Management**: Connection pool_size: 50 for high concurrency

## Development Workflows

### Essential Commands
```bash
# Setup (requires PostgreSQL)
mix setup                    # Full setup: deps, DB, assets
make docker-compose-up       # Start PostgreSQL container
iex -S mix phx.server       # Development with live reload

# Database
mix ecto.reset              # Drop/create/migrate/seed
mix test                    # Always run full suite (only --trace option allowed)

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

#### Producer Implementation Pattern
```elixir
defmodule MyApp.MyPipeline.Producer do
  use GenStage
  
  # State management
  def handle_demand(demand, state) when demand > 0 do
    new_state = %{state | demand: state.demand + demand}
    dispatch_if_ready(new_state)
  end
  
  # Availability checking
  defp should_dispatch?(state) do
    state.status == :running and worker_available?()
  end
  
  # Telemetry emission
  defp emit_queue_telemetry(measurements, metadata) do
    :telemetry.execute([:app, :pipeline, :queue_changed], measurements, metadata)
  end
end
```

#### Broadway Configuration Pattern
```elixir
def start_link(opts) do
  config = Application.get_env(:app, Broadway, [])
  |> Keyword.merge(@default_config)
  |> Keyword.merge(opts)
  
  Broadway.start_link(__MODULE__,
    name: __MODULE__,
    producer: [module: {Producer, []}],
    processors: [default: [concurrency: 1]],
    batchers: [default: [batch_size: config[:batch_size]]]
  )
end
```

### Database Query Patterns
```elixir
# Array operations for codec filtering
fragment("EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))", 
         v.audio_codecs, "%opus%")

# State queries use enum states, not boolean flags
where: v.state not in [:encoded, :failed]
where: v.state == :needs_analysis

# Optimized queue queries with limits and ordering
def get_videos_needing_analysis(limit \\ 50) do
  from(v in Video,
    where: v.state == :needs_analysis,
    order_by: [asc: v.updated_at],
    limit: ^limit
  )
end
```

### Video State Management
- **State Machine**: `VideoStateMachine` enforces valid transitions between processing states
- **State Flow**: `needs_analysis → analyzed → crf_searching → crf_searched → encoding → encoded`
- **State Functions**: Use `VideoStateMachine.transition_to_*()` functions instead of direct updates
- **Error Handling**: `failed` state is terminal, use `mark_as_failed/1` for error transitions

#### State Machine Implementation
```elixir
# Valid transitions defined in module attribute
@valid_transitions %{
  needs_analysis: [:analyzed, :crf_searched, :failed],
  analyzed: [:crf_searching, :crf_searched, :failed],
  crf_searching: [:crf_searched, :failed, :analyzed],
  crf_searched: [:encoding, :failed, :crf_searching],
  encoding: [:encoded, :failed, :crf_searched],
  encoded: [:failed],
  failed: [:needs_analysis, :analyzed, :crf_searching, :crf_searched, :encoding]
}

# Usage pattern
def process_video(video) do
  with {:ok, changeset} <- VideoStateMachine.transition_to_analyzed(video),
       {:ok, updated_video} <- Repo.update(changeset) do
    {:ok, updated_video}
  end
end
```

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

#### External Service Integration Pattern
```elixir
defmodule Reencodarr.Services.MyService do
  use CarReq,
    pool_timeout: 100,
    receive_timeout: 9_000,
    retry: :safe_transient,
    max_retries: 3,
    fuse_opts: {{:standard, 5, 30_000}, {:reset, 60_000}}
    
  def sync_data do
    case get("/api/endpoint") do
      {:ok, %{status: 200, body: data}} -> process_data(data)
      {:error, reason} -> {:error, reason}
    end
  end
end
```

#### Webhook Handling (`lib/reencodarr_web/controllers/sonarr_webhook_controller.ex`)
- **Event Types**: `Download`, `Rename`, `SeriesAdd`, `SeriesDelete` with specific handlers
- **File Upserts**: Automatic video creation via `Sync.upsert_video_from_file/2`
- **MediaInfo Conversion**: Service-specific data transformed to internal schema
- **Path Management**: Handles file moves/renames with video record updates

#### Configuration Management
```elixir
# Database-stored configs with service typing
configs = [
  %{service_type: :sonarr, url: "http://sonarr:8989", api_key: "abc123"},
  %{service_type: :radarr, url: "http://radarr:7878", api_key: "def456"}
]

# Runtime config resolution
def get_service_config(service_type) do
  from(c in Config, where: c.service_type == ^service_type)
  |> Repo.one()
end
```

### Testing Considerations
- **Manual Sandbox**: Set in `test/test_helper.exs` for transaction isolation
- **Disabled Services**: Analyzer supervisor disabled in test to prevent conflicts
- **Mocking**: Use `meck` for external command simulation
- **Fixtures**: Comprehensive test data generators in `test/support/fixtures.ex`

#### Testing Pattern for Broadway Pipelines
```elixir
defmodule MyApp.Broadway.Test do
  use MyApp.DataCase
  
  setup do
    # Broadway pipelines disabled in test env
    # Test configuration merging logic instead
    app_config = Application.get_env(:myapp, Broadway, [])
    default_config = [rate_limit_messages: 10, batch_size: 1]
    
    final_config = default_config 
    |> Keyword.merge(app_config) 
    |> Keyword.merge(opts)
    
    %{config: final_config}
  end
end
```

### LiveView Architecture
Phoenix LiveView with optimized real-time updates:

#### Event-Driven UI Updates
```elixir
defmodule MyAppWeb.DashboardLive do
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :telemetry.attach_many(handler_id, events, &handle_telemetry_event/4, 
                            %{live_view_pid: self()})
    end
    {:ok, socket}
  end
  
  def handle_info({:telemetry_event, state}, socket) do
    dashboard_data = Presenter.present(state, socket.assigns.timezone)
    {:noreply, assign(socket, :dashboard_data, dashboard_data)}
  end
end
```

#### LCARS UI Component System
- **Shared Components**: Consistent LCARS (Star Trek) theming across all pages
- **Stream Optimization**: Phoenix LiveView streams for large queue displays
- **Memory Management**: Presenter pattern for data transformation
- **Real-time Updates**: Telemetry-driven state synchronization

### File Operations
`FileOperations.move_file/4` handles cross-device moves with copy+delete fallback for EXDEV errors.

### AB-AV1 Command Execution & Output Capture
The ab-av1 CLI tool is launched and managed through a sophisticated port-based architecture with centralized output processing:

#### Centralized ProgressParser Architecture (`lib/reencodarr/ab_av1/progress_parser.ex`)
All ab-av1 output processing flows through a single entry point that provides:
- **Context-Aware Dispatching**: Automatically detects encoding vs CRF search operations
- **Unified Interface**: Single `process_line/2` function handles all ab-av1 output
- **Structured Parsing**: Delegates to `OutputParser` for pattern matching, then routes to appropriate handlers
- **Telemetry Integration**: Emits structured telemetry events for real-time dashboard updates

```elixir
# Usage in both encoding and CRF search contexts
# Encoding context (from Encode GenServer)
ProgressParser.process_line(line, %{video: video})

# CRF search context (from CrfSearch GenServer)  
ProgressParser.process_line(line, {video, args, target_vmaf})
```

#### Port Creation (`Helper.open_port/1`)
```elixir
# Command launching with preprocessing
Port.open({:spawn_executable, path}, [
  :binary,          # Binary mode for output
  :exit_status,     # Capture exit codes
  :line,            # Line-buffered output
  :use_stdio,       # Use stdin/stdout
  :stderr_to_stdout, # Merge stderr into stdout
  args: cleaned_args # Preprocessed arguments
])
```

#### Input File Preprocessing
- **MKV Attachment Cleaning**: Removes image attachments that can cause encoding issues
- **Argument Sanitization**: Validates and cleans command arguments
- **Path Resolution**: Handles complex file paths and special characters

#### Output Capture Pattern
Each GenServer maintains:
- **Port State**: Active port reference or `:none` when idle
- **Line Buffering**: `partial_line_buffer` for incomplete lines (`:noeol` messages)
- **Output History**: `output_buffer` array for failure analysis and debugging
- **Progress Parsing**: Real-time parsing via `ProgressParser.process_line/2`

#### Message Flow
```elixir
# Complete lines trigger immediate parsing
{port, {:data, {:eol, data}}} ->
  full_line = partial_line_buffer <> data
  ProgressParser.process_line(full_line, state)
  
# Partial lines are buffered
{port, {:data, {:noeol, message}}} ->
  new_buffer = partial_line_buffer <> message
  
# Process termination with exit codes
{port, {:exit_status, exit_code}} ->
  handle_completion_or_failure(exit_code, output_buffer)
```

#### Centralized Output Parsing (`AbAv1.OutputParser`)
- **Regex Patterns**: Comprehensive pattern matching for all ab-av1 output types
- **Structured Data**: Converts raw text to typed fields (CRF, VMAF scores, progress %)
- **Pattern Types**: Encoding progress, VMAF results, error messages, success indicators
- **Field Mapping**: Declarative parsing with type conversion and validation

#### Progress Tracking & Telemetry Flow
```
ab-av1 stdout/stderr → Port → ProgressParser → OutputParser → Context Handlers → Telemetry
                                    ↓                              ↓
                              Context Detection              Appropriate Handler
                            (encoding vs CRF search)      (encoding_progress vs vmaf_result)
                                                                   ↓
                                                           Telemetry.emit_*()
```

#### Error Handling & Failure Recovery
- **Exit Code Classification**: Distinguishes system vs. file-specific failures
- **Output Preservation**: Full command output saved for failure analysis
- **Automatic Retry**: Preset 6 fallback for encoding failures
- **Pipeline Coordination**: Proper cleanup and producer notification

### Centralized ab-av1 Output Processing

#### OutputParser Architecture (`lib/reencodarr/ab_av1/output_parser.ex`)
Comprehensive regex patterns for structured ab-av1 output parsing:

**Pattern Categories**:
```elixir
# Progress tracking patterns
encoding_progress: ~r/(?<percent>\d+)%,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours)/

# VMAF quality patterns  
simple_vmaf: ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/
eta_vmaf: ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+),\s*estimated\s*file\s*size\s*(?<size>[\d\.]+)\s*(?<unit>\w+)/

# Lifecycle patterns
encoding_start: ~r/Starting.*encoding.*for.*(?<filename>[^,]+)/
success: ~r/Successfully.*(?:completed|encoded)/
```

**Pattern Specificity Ordering**: Most specific patterns first to prevent incorrect matching:
1. **eta_vmaf** (with size estimates) 
2. **simple_vmaf** (basic CRF/VMAF scores)
3. **encoding_progress** (general progress)
4. **encoding_start** (initialization)

**Structured Parsing**: Converts raw ab-av1 output to typed data with proper field extraction and validation.

### Rules-Based Argument Building
The `Rules` module provides centralized argument construction for ab-av1 commands with context-aware filtering:

#### Core Function: `Rules.build_args/4`
```elixir
def build_args(video, context, additional_params \\ [], base_args \\ [])
```

#### Argument Flow Architecture
1. **Rule Application**: Video-specific rules generate argument tuples
2. **Parameter Processing**: Convert flat lists to tuples with context filtering  
3. **Tuple Combination**: Merge base args, additional params, and rule-based args
4. **Deduplication**: Remove duplicate flags (keeping first occurrence)
5. **Conversion**: Transform tuples to final command line arguments

#### Context-Based Filtering
- **`:crf_search`** - Excludes audio parameters for quality analysis
- **`:encode`** - Includes all parameters for final encoding

#### Rule Categories
```elixir
# Applied conditionally based on context
rules_to_apply = [
  &hdr/1,        # HDR/SDR detection: tune=0, dolbyvision=1
  &resolution/1, # 4K downscaling: scale=1920:-2  
  &video/1,      # Base video: pix-format=yuv420p10le
  &audio/1       # Audio transcoding (encode context only)
]
```

#### Audio Rule Logic
```elixir
# Opus codec detection and bitrate calculation
cond do
  atmos == true -> []  # Skip Atmos content
  @opus_codec_tag in audio_codecs -> []  # Already Opus
  channels == 3 -> upmix_to_5_1()  # 3.0 -> 5.1 conversion
  true -> build_opus_config(channels)
end
```

#### Parameter Merging Priority
1. **Subcommands** (`"crf-search"`, `"encode"`) - Always first
2. **Base arguments** - Core flags like `--input`, `--output`
3. **Additional parameters** - From VMAF retries, user overrides
4. **Rule-based parameters** - Generated from video characteristics

#### Deduplication Strategy
- **Single flags** - Keep first occurrence (base args override rules)
- **Multi-value flags** - Allow multiple `--svt` and `--enc` entries
- **Flag normalization** - Convert `-i` to `--input` for consistency

#### Usage Examples
```elixir
# CRF search with preset 6 retry
Rules.build_args(video, :crf_search, ["--preset", "6"], base_crf_args)

# Encoding with VMAF parameters  
Rules.build_args(video, :encode, vmaf.params, base_encode_args)

# Context filtering in action
crf_args = Rules.build_args(video, :crf_search)    # No audio args
encode_args = Rules.build_args(video, :encode)     # Includes audio args
```

## Key Directories
- `lib/reencodarr/{analyzer,crf_searcher,encoder}/` - Broadway pipelines with producers/supervisors
- `lib/reencodarr/services/` - External API clients with circuit breakers
- `lib/reencodarr/ab_av1/` - Command execution, output parsing, and GenServer workers
- `lib/reencodarr/media/` - Database models, state machine, and query modules
- `lib/reencodarr_web/live/` - Phoenix LiveView modules with real-time UI
- `lib/reencodarr_web/controllers/` - Webhook handlers for external service integration
- `test/support/` - Shared test utilities, fixtures, and Broadway test patterns
- `priv/repo/migrations/` - Database schema with enum types and indexes

## Complete ab-av1 to Dashboard Telemetry Flow

This section documents the complete flow of telemetry data from ab-av1 command execution to real-time dashboard updates:

### 1. ab-av1 Process Execution
```
GenServer (CrfSearch/Encode) → Port.open() → ab-av1 CLI Process
```
- GenServer launches ab-av1 via port with cleaned arguments
- Port configured for line-buffered binary output capture
- Both stdout and stderr merged into single stream

### 2. Output Capture & Parsing
```
ab-av1 stdout/stderr → Port Messages → ProgressParser.process_line/2
```
- Port receives `:eol` and `:noeol` messages from ab-av1 output
- Lines buffered until complete, then passed to `ProgressParser.process_line/2`
- Context determined automatically (encoding vs CRF search)

### 3. Structured Output Processing
```
ProgressParser → OutputParser.parse_line/1 → Context Handlers
```
- `OutputParser` uses regex patterns to extract structured data
- Pattern specificity ordering ensures correct parsing
- Context handlers emit appropriate telemetry events

### 4. Telemetry Event Emission
```
Context Handlers → Telemetry.emit_*() → :telemetry.execute()
```
Examples of emitted events:
- `[:reencodarr, :encoder, :progress]` - Encoding progress updates
- `[:reencodarr, :encoder, :started]` - Encoding initiation
- `[:reencodarr, :crf_search, :progress]` - CRF search VMAF results

### 5. Event Handler Routing
```
:telemetry.execute() → TelemetryEventHandler → TelemetryReporter GenServer
```
- `TelemetryEventHandler` routes events to `TelemetryReporter` via GenServer.cast
- Events categorized by type (encoder, crf_search, analyzer, queue, sync)
- Each event type triggers specific state updates

### 6. State Consolidation & Filtering
```
TelemetryReporter → DashboardState Updates → Significance Detection
```
- All telemetry consolidated into single `DashboardState` struct
- Progress changes filtered (>1% threshold to prevent UI spam)
- Memory-optimized state comparison using process dictionary

### 7. Dashboard State Broadcasting
```
TelemetryReporter → :telemetry.execute([:reencodarr, :dashboard, :state_updated])
```
- Only significant state changes trigger dashboard telemetry
- Minimal payload sent (50-70% size reduction)
- Inactive progress data excluded from payloads

### 8. LiveView Integration
```
:telemetry.execute() → LiveView.handle_telemetry_event/4 → UI Updates
```
- Dashboard LiveView attaches to `[:reencodarr, :dashboard, :state_updated]` events
- Telemetry handler sends messages to LiveView process
- UI updates happen via `handle_info({:telemetry_event, state})`

### Complete Flow Example
```
ab-av1: "50%, 25.5 fps, eta 5 minutes"
  ↓
Port message: {:data, {:eol, "50%, 25.5 fps, eta 5 minutes"}}
  ↓
ProgressParser.process_line("50%, 25.5 fps, eta 5 minutes", %{video: video})
  ↓
OutputParser.parse_line() → {:ok, %{type: :progress, data: %{progress: 50, fps: 25.5, eta: 5, eta_unit: "minutes"}}}
  ↓
handle_encoding_progress() → Telemetry.emit_encoder_progress(%{filename: "video.mkv", percent: 50, fps: 25.5, eta: "5 minutes"})
  ↓
:telemetry.execute([:reencodarr, :encoder, :progress], measurements, metadata)
  ↓
TelemetryEventHandler.handle_event() → GenServer.cast(TelemetryReporter, {:update_encoding_progress, measurements})
  ↓
TelemetryReporter updates DashboardState → emit_state_update_and_return()
  ↓
:telemetry.execute([:reencodarr, :dashboard, :state_updated], %{}, %{state: minimal_state})
  ↓
DashboardLive.handle_telemetry_event() → send(pid, {:telemetry_event, state})
  ↓
DashboardLive.handle_info({:telemetry_event, state}) → UI progress bar updates
```

This architecture provides real-time, efficient updates with automatic filtering and memory optimization.

## Performance & Debugging Patterns

### Broadway Pipeline Debugging
```bash
# Check producer status
iex> Reencodarr.Analyzer.Broadway.Producer.debug_status()

# Monitor telemetry events
iex> :telemetry.list_handlers([:reencodarr])

# Check GenServer availability
iex> Reencodarr.AbAv1.CrfSearch.status()
```

### Queue State Monitoring
```elixir
# Real-time queue state from producers
def get_queue_state do
  %{
    analyzer: get_videos_needing_analysis() |> length(),
    crf_searcher: get_videos_needing_crf_search() |> length(),
    encoder: get_vmafs_needing_encoding() |> length()
  }
end
```

### Memory Optimization Techniques
- **Process Dictionary**: Last state caching in TelemetryReporter
- **Selective Telemetry**: Only emit events on significant changes (>1% deltas)
- **Stream Processing**: Phoenix LiveView streams for large datasets
- **Database Connection Pooling**: Optimized pool_size for concurrent Broadway processing
