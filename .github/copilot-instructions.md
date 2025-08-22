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
Real-time dashboard updates without polling:

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
The ab-av1 CLI tool is launched and managed through a sophisticated port-based architecture:

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

#### Progress Tracking & Telemetry
Real-time updates flow through:
1. **Raw Output**: Port captures ab-av1 stdout/stderr
2. **Line Parsing**: `OutputParser` converts to structured data
3. **Progress Events**: `ProgressParser` emits telemetry with progress percentages
4. **Dashboard Updates**: Telemetry flows to UI via PubSub for real-time feedback

#### Error Handling & Failure Recovery
- **Exit Code Classification**: Distinguishes system vs. file-specific failures
- **Output Preservation**: Full command output saved for failure analysis
- **Automatic Retry**: Preset 6 fallback for encoding failures
- **Pipeline Coordination**: Proper cleanup and producer notification

### Progress Parsing
Complex regex patterns in `@patterns` maps for ab-av1 output parsing:
```elixir
simple_vmaf: ~r/crf\s(?<crf>\d+(?:\.\d+)?)\sVMAF\s(?<score>\d+\.\d+)\s\((?<percent>\d+)%\)/
encoding_progress: ~r/(?<percent>\d+)%,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours)/
```

## Key Directories
- `lib/reencodarr/{analyzer,crf_searcher,encoder}/` - Broadway pipelines with producers/supervisors
- `lib/reencodarr/services/` - External API clients with circuit breakers
- `lib/reencodarr/ab_av1/` - Command execution and parsing with GenServer workers
- `lib/reencodarr/media/` - Database models, state machine, and query modules
- `lib/reencodarr_web/live/` - Phoenix LiveView modules with real-time UI
- `lib/reencodarr_web/controllers/` - Webhook handlers for external service integration
- `test/support/` - Shared test utilities, fixtures, and Broadway test patterns
- `priv/repo/migrations/` - Database schema with enum types and indexes

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
