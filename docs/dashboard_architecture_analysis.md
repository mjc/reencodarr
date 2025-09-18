# Current Dashboard Architecture Analysis

## THE PROBLEM: Too Many Layers and Complex State Flow

The current dashboard system has **8 LAYERS** of state management PLUS **20+ TELEMETRY EVENTS** and **15+ PUBSUB BROADCASTS** creating a massive web of complexity:

```
USER INTERACTION (Button Click)
    ↓
1. LiveView (dashboard_live.ex)
    ↓ handle_event/3
2. Broadway Pipeline (crf_searcher/broadway.ex) 
    ↓ pause()/resume() calls Producer
3. Broadway Producer (crf_searcher/broadway/producer.ex)
    ↓ emits MULTIPLE telemetry events AND PubSub broadcasts
4. TelemetryEventHandler (telemetry_event_handler.ex)
    ↓ routes 20+ different events to reporter
5. TelemetryReporter GenServer (telemetry_reporter.ex)
    ↓ updates DashboardState + emits more telemetry
6. DashboardState (dashboard_state.ex)
    ↓ determines status via Broadway.running?() + telemetry state
7. Progress Normalizer (progress/normalizer.ex)
    ↓ formats progress data
8. Dashboard Presenter (dashboard/presenter.ex)
    ↓ presents data to UI
```

## ALL TELEMETRY EVENTS IN THE SYSTEM

### Encoder Events (6 events):
- `[:reencodarr, :encoder, :started]` → TelemetryReporter.update_encoding(true)
- `[:reencodarr, :encoder, :progress]` → TelemetryReporter.update_encoding_progress()
- `[:reencodarr, :encoder, :completed]` → TelemetryReporter.update_encoding(false)
- `[:reencodarr, :encoder, :failed]` → TelemetryReporter.update_encoding(false)
- `[:reencodarr, :encoder, :paused]` → TelemetryReporter.update_encoding(false)
- `[:reencodarr, :encoder, :queue_changed]` → TelemetryReporter.update_queue_state()

### CRF Search Events (5 events):
- `[:reencodarr, :crf_search, :started]` → TelemetryReporter.update_crf_search(true)
- `[:reencodarr, :crf_search, :progress]` → TelemetryReporter.update_crf_search_progress()
- `[:reencodarr, :crf_search, :completed]` → TelemetryReporter.update_crf_search(false)
- `[:reencodarr, :crf_search, :paused]` → TelemetryReporter.update_crf_search(false)
- `[:reencodarr, :crf_searcher, :queue_changed]` → TelemetryReporter.update_queue_state()

### Analyzer Events (4 events):
- `[:reencodarr, :analyzer, :started]` → TelemetryReporter.update_analyzer(true)
- `[:reencodarr, :analyzer, :paused]` → TelemetryReporter.update_analyzer(false)
- `[:reencodarr, :analyzer, :throughput]` → TelemetryReporter.update_analyzer_throughput()
- `[:reencodarr, :analyzer, :queue_changed]` → TelemetryReporter.update_queue_state()

### Sync Events (4 events):
- `[:reencodarr, :sync, :started]` → TelemetryReporter.update_sync()
- `[:reencodarr, :sync, :progress]` → TelemetryReporter.update_sync()
- `[:reencodarr, :sync, :completed]` → TelemetryReporter.update_sync()
- `[:reencodarr, :sync, :failed]` → TelemetryReporter.update_sync()

### Media Events (2 events):
- `[:reencodarr, :media, :video_upserted]` → Video state change processing
- `[:reencodarr, :media, :vmaf_upserted]` → VMAF data processing

### Dashboard Meta Event (1 event):
- `[:reencodarr, :dashboard, :state_updated]` → LiveView telemetry updates

**TOTAL: 22 DIFFERENT TELEMETRY EVENTS**

## ALL PUBSUB BROADCASTS IN THE SYSTEM

### Broadway Producer Broadcasts:
- `"analyzer"` channel: `{:analyzer, :started}`, `{:analyzer, :paused}`
- `"crf_searcher"` channel: `{:crf_searcher, :started}`, `{:crf_searcher, :paused}`
- `"encoder"` channel: `{:encoder, :started}`, `{:encoder, :paused}`

### AbAv1 Process Broadcasts:
- `"crf_search_progress"` channel: CRF search progress updates
- `"crf_search_status"` channel: CRF search status changes
- `"encoding_progress"` channel: Encoding progress updates
- `"encoding_status"` channel: Encoding status changes
- `"video_state_transitions"` channel: Video state changes

### Queue Manager Broadcasts:
- Queue state updates for analyzer
- Video addition/removal notifications

### Statistics Broadcasts:
- `"stats"` channel: Statistics updates

**TOTAL: 15+ DIFFERENT PUBSUB TOPICS WITH MULTIPLE MESSAGE TYPES**

## CURRENT STATE FLOW ANALYSIS

### 1. CRF Search Status Flow (THE NIGHTMARE)
```elixir
# Button Click → "Resume/Pause CRF Search"
DashboardLive.handle_event("toggle_crf_search") →
  CrfSearcher.Broadway.pause() OR resume() →
    Producer.pause() OR resume() →
      # PARALLEL CHAOS:
      
      # PATH 1: PubSub Broadcast
      PubSub.broadcast("crf_searcher", {:crf_searcher, :paused/:started}) →
        (Nothing subscribes to this!)
        
      # PATH 2: Telemetry Events  
      Telemetry.emit_crf_search_paused() OR emit_crf_search_started() →
        TelemetryEventHandler.handle_event([:reencodarr, :crf_search, :paused/:started]) →
          TelemetryReporter.handle_cast({:update_crf_search, false/true}) →
            DashboardState.update_crf_search(state, status) →
              TelemetryReporter emits MORE telemetry:
              :telemetry.execute([:reencodarr, :dashboard, :state_updated]) →
                DashboardLive.handle_telemetry_event() →
                  Presenter.present() →
                    Normalizer.normalize_progress() →
                      UI Update
                      
      # PATH 3: Status Check (CONFLICTS WITH PATH 2!)
      DashboardState.crf_searcher_running?() calls Broadway.running?() →
        Producer.running?() calls GenStage.call(producer_pid, :running?) →
          Returns process alive status (NOT pause/resume status!)
```

### 2. CRF Search Progress Flow (EVEN WORSE)
```elixir
# Progress Updates from ab-av1 process
AbAv1.CrfSearch.handle_info({port, {:data, data}}) →
  parse_crf_output(data) →
    broadcast_crf_search_progress() →
      # TRIPLE BROADCAST!
      
      # PATH 1: PubSub (broadcast_crf_search_progress)
      PubSub.broadcast("crf_search_progress", progress) →
        (Nothing subscribes!)
        
      # PATH 2: Telemetry (emit_progress_safely)  
      Telemetry.emit_crf_search_progress(progress) →
        TelemetryEventHandler.handle_event([:reencodarr, :crf_search, :progress]) →
          TelemetryReporter.handle_cast({:update_crf_search_progress, measurements}) →
            DashboardState updates crf_search_progress →
              TelemetryReporter.emit_state_update_and_return() →
                :telemetry.execute([:reencodarr, :dashboard, :state_updated]) →
                  DashboardLive.handle_telemetry_event() →
                    Presenter.present() →
                      Normalizer.normalize_progress() →
                        UI Update (maybe, if normalizer doesn't return empty!)
                        
      # PATH 3: More PubSub (in broadcast_crf_search_progress)
      PubSub.broadcast("crf_search_status", {:started, video.path}) →
        (Nothing subscribes!)
```

### 3. Multiple Sources of Truth Creating Chaos
```elixir
# For "Is CRF Search Running?" we have:
1. Broadway.running?() → Process.alive?(producer_pid) → TRUE/FALSE
2. DashboardState.crf_searching → From telemetry events → TRUE/FALSE  
3. CrfSearchProgress.filename → :none means not running → :none/string
4. AbAv1.CrfSearch GenServer state → {:current_task, task} → nil/task

# All four can disagree!
# Producer process alive = TRUE
# Telemetry says paused = FALSE
# Progress has filename = "video.mkv" 
# AbAv1 task = nil
# Result: UI shows random state!
```

## ROOT CAUSES OF ISSUES

### Issue 1: Button Shows Wrong State
- **Problem**: Button state comes from `DashboardState.crf_searcher_running?()`
- **Cause**: This calls `Broadway.running?()` which checks if Producer GenStage process is alive
- **Mismatch**: Producer can be "running" (process alive) but CRF search can be "paused" (not processing)
- **Additional Chaos**: 22 different telemetry events can affect state, but only some update the button

### Issue 2: Progress Not Showing
- **Problem**: Progress normalizer returns `empty_progress()` 
- **Cause**: CRF search progress has `filename: :none` initially, complex normalizer logic with 4 different checks
- **Fix Attempted**: Added CRF/score detection, but telemetry can be debounced/lost in the 8-layer chain
- **Root Issue**: Progress goes through 8 transformation layers, each can lose/modify data

### Issue 3: State Synchronization Hell
- **Problem**: Multiple sources of truth for "is CRF search active?"
  1. `Broadway.running?()` (process alive? - YES/NO)
  2. `DashboardState.crf_searching` (telemetry events - TRUE/FALSE)
  3. `CrfSearchProgress.filename` (actual progress - :none/string)
  4. `AbAv1.CrfSearch` GenServer state (current task - nil/task)
  5. PubSub messages (15+ different topics, some unused!)
- **Result**: UI shows inconsistent states because different parts read different sources

### Issue 4: Event Explosion
- **Problem**: 22 telemetry events + 15 PubSub topics + 8 processing layers
- **Cause**: Each Broadway producer emits queue_changed events every few seconds
- **Effect**: GenServer message queues flood, events get delayed/dropped/reordered
- **Debugging**: Impossible to trace which event caused which UI change

### Issue 5: Unused Communication Channels
- **Problem**: Many PubSub broadcasts have NO subscribers
- **Examples**: 
  - `"crf_searcher"` channel broadcasts - nothing listens
  - `"crf_search_progress"` - nothing subscribes  
  - `"crf_search_status"` - nothing subscribes
- **Effect**: Wasted CPU cycles, confusing architecture

### Issue 6: Race Conditions
- **Problem**: Multiple async paths updating same UI state
- **Example**: Telemetry says CRF paused, but progress update comes later showing filename
- **Result**: UI flickers between states or shows impossible combinations

## PROPOSED SIMPLIFIED ARCHITECTURE

Instead of 8 layers, let's use **3 LAYERS**:

```
USER INTERACTION
    ↓
1. LiveView + Simple State Manager
    ↓ direct calls
2. Service Layer (Broadway/GenServers)
    ↓ simple events  
3. Direct UI Updates (PubSub)
```

### New Flow:
```elixir
# Button Click
DashboardLive.handle_event("toggle_crf_search") →
  CrfSearcher.toggle() →  # Simple wrapper
    Broadway.pause() OR resume() →
      PubSub.broadcast("crf_search_status", {:paused/:running, progress_data}) →
        LiveView.handle_info({:crf_search_status, status, progress}) →
          Direct assign updates
```

### Benefits:
1. **Single source of truth**: Service layer broadcasts complete state
2. **No complex state management**: LiveView just assigns what it receives  
3. **No telemetry complexity**: Direct PubSub messages
4. **No normalizer complexity**: Service layer sends UI-ready data
5. **Immediate consistency**: One message contains both status and progress

Would you like me to implement this simplified architecture?

## DETAILED IMPLEMENTATION PLAN

### Phase 1: CRF Search 3-Layer Implementation

#### Step 1: Update CrfSearcher Service
```elixir
defmodule Reencodarr.CrfSearcher do
  # Add direct PubSub broadcasts
  def start_search(video_id) do
    case AbAv1.CrfSearch.start(video_id) do
      {:ok, _pid} ->
        PubSub.broadcast("crf_search", {:started, video_id, %{progress: 0, status: :running}})
        {:ok, :started}
      {:error, reason} ->
        PubSub.broadcast("crf_search", {:error, video_id, reason})
        {:error, reason}
    end
  end

  def pause_search() do
    case AbAv1.CrfSearch.pause() do
      :ok ->
        PubSub.broadcast("crf_search", {:paused, nil, %{status: :paused}})
        :ok
      {:error, reason} ->
        PubSub.broadcast("crf_search", {:error, nil, reason})
        {:error, reason}
    end
  end
end
```

#### Step 2: Update AbAv1.CrfSearch GenServer
```elixir
# Add progress broadcasts directly in handle_info
def handle_info({:progress_update, data}, state) do
  # Parse progress from ab-av1 output
  progress_data = %{
    progress: extract_progress_percent(data),
    crf: extract_current_crf(data),
    vmaf: extract_vmaf_score(data),
    filename: state.video_filename
  }
  
  PubSub.broadcast("crf_search", {:progress, state.video_id, progress_data})
  {:noreply, state}
end

def handle_info({:search_completed, results}, state) do
  PubSub.broadcast("crf_search", {:completed, state.video_id, results})
  {:noreply, %{state | status: :idle}}
end
```

#### Step 3: Simplify Dashboard LiveView
```elixir
defmodule ReencodarrWeb.DashboardLive do
  def mount(_params, _session, socket) do
    # Only subscribe to what we need
    PubSub.subscribe("crf_search")
    
    {:ok, assign(socket,
      crf_search_active: false,
      crf_search_progress: nil,
      crf_search_data: %{}
    )}
  end

  # Direct message handlers - no normalization layers
  def handle_info({:started, video_id, data}, socket) do
    {:noreply, assign(socket, 
      crf_search_active: true,
      crf_search_progress: data,
      current_crf_video_id: video_id
    )}
  end

  def handle_info({:progress, video_id, data}, socket) do
    {:noreply, assign(socket, crf_search_progress: data)}
  end

  def handle_info({:completed, video_id, results}, socket) do
    {:noreply, assign(socket, 
      crf_search_active: false,
      crf_search_progress: nil,
      last_crf_results: results
    )}
  end

  def handle_info({:paused, _video_id, _data}, socket) do
    {:noreply, assign(socket, crf_search_active: false)}
  end
end
```

#### Step 4: Update Templates
```heex
<!-- Simple button state -->
<button phx-click="toggle_crf_search" 
        class={if @crf_search_active, do: "btn btn-error", else: "btn btn-primary"}>
  <%= if @crf_search_active, do: "Stop CRF Search", else: "Start CRF Search" %>
</button>

<!-- Direct progress display -->
<%= if @crf_search_progress && @crf_search_active do %>
  <div class="progress-container">
    <div>Progress: <%= @crf_search_progress.progress %>%</div>
    <%= if @crf_search_progress.crf do %>
      <div>Testing CRF: <%= @crf_search_progress.crf %></div>
    <% end %>
    <%= if @crf_search_progress.vmaf do %>
      <div>VMAF Score: <%= @crf_search_progress.vmaf %></div>
    <% end %>
  </div>
<% end %>
```

### Phase 2: Remove Old Complexity

#### Files to Delete/Simplify:
- `lib/reencodarr/dashboard_state.ex` - Remove entirely
- `lib/reencodarr/telemetry_reporter.ex` - Remove entirely  
- `lib/reencodarr/dashboard/queue_builder.ex` - Simplify or remove
- `lib/reencodarr/progress/normalizer.ex` - Remove CRF search logic
- All unused telemetry events and PubSub channels

#### Broadway Pipeline Updates:
- Remove telemetry emissions from producer tick functions
- Keep only essential telemetry for metrics (not UI updates)
- Remove queue_changed broadcasts if not used by simplified UI

### Phase 3: Testing Strategy

#### Unit Tests:
```elixir
# Test direct PubSub messages
test "CrfSearcher.start_search broadcasts started event" do
  video_id = 123
  
  PubSub.subscribe("crf_search")
  CrfSearcher.start_search(video_id)
  
  assert_receive {:started, ^video_id, %{progress: 0, status: :running}}
end
```

#### Integration Tests:
```elixir  
# Test LiveView message handling
test "dashboard updates when CRF search starts" do
  {:ok, view, _html} = live(conn, "/")
  
  # Simulate service broadcasting
  PubSub.broadcast("crf_search", {:started, 123, %{progress: 0}})
  
  assert has_element?(view, "button", "Stop CRF Search")
end
```

Would you like me to start implementing Phase 1?

## WHY NOT USE TELEMETRY FOR UI UPDATES?

**Important**: Telemetry itself isn't bad - it's being **misused** in this codebase for real-time UI state management instead of metrics collection.

### The Misuse Problem

#### Current (Wrong): Telemetry for UI State
```elixir
# CURRENT: Using telemetry for UI state
:telemetry.execute([:crf_search, :started], %{video_id: 123})
# Goes through: TelemetryReporter → DashboardState → Progress.Normalizer → LiveView
# Result: 4+ async steps, can fail/delay at any point

# UI gets inconsistent/delayed updates
```

#### Better: Direct PubSub for UI State
```elixir
# BETTER: Direct PubSub for UI state  
PubSub.broadcast("crf_search", {:started, 123, %{progress: 0}})
# Goes directly to: LiveView
# Result: 1 step, immediate consistency
```

### Specific Problems with Telemetry for UI

#### 1. Event Ordering & Loss Issues
```elixir
# With telemetry: These can arrive out of order or get dropped
:telemetry.execute([:crf_search, :progress], %{percent: 50})
:telemetry.execute([:crf_search, :progress], %{percent: 75})  
:telemetry.execute([:crf_search, :completed], %{})

# UI might see: 50% → completed → 75% (wrong order!)
# Or: 50% → completed (lost the 75% event)
```

#### 2. Multiple Processing Layers Create Bugs
Our telemetry goes through **4+ transformation layers**:
```
AbAv1.CrfSearch → :telemetry.execute() → 
TelemetryReporter (GenServer queue) → 
DashboardState (more GenServer state) → 
Progress.Normalizer (complex logic) → 
LiveView (finally!)
```

**Each layer can:**
- Transform data differently
- Have different timing
- Cache stale state  
- Drop messages when queues are full

#### 3. Race Conditions
```elixir
# Two different telemetry events can race:
:telemetry.execute([:broadway, :queue_changed])  # Says "CRF search paused"
:telemetry.execute([:crf_search, :progress])     # Says "45% complete"

# UI shows impossible state: "CRF search paused" + "45% progress"
```

#### 4. Debugging Nightmare
- **22 different telemetry events** can affect UI state
- Multiple GenServer queues can delay/reorder events
- Complex state transformations hide the source of bugs
- "Which of 22 events caused this UI bug?"

### When Telemetry IS Good

Telemetry should be used for:

#### Metrics & Observability
```elixir
# GOOD: Track performance metrics
:telemetry.execute([:video, :analysis], %{duration: 2500}, %{video_id: 123})

# GOOD: Error tracking  
:telemetry.execute([:encoding, :failed], %{reason: :timeout})

# GOOD: Business metrics
:telemetry.execute([:videos, :processed], %{count: 1})
```

#### Logging & Debugging
```elixir
# GOOD: Structured logging for later analysis
:telemetry.execute([:crf_search, :completed], %{
  video_id: 123,
  duration: 30_000,
  final_crf: 23,
  vmaf_score: 95.2
})
```

### Proposed Hybrid Architecture

```elixir
# For UI updates: Direct PubSub (immediate, ordered)
def start_crf_search(video_id) do
  case AbAv1.CrfSearch.start(video_id) do
    {:ok, _pid} ->
      # UI gets immediate update
      PubSub.broadcast("crf_search", {:started, video_id})
      
      # Metrics get async collection for dashboards/monitoring
      :telemetry.execute([:crf_search, :started], %{video_id: video_id})
      
    {:error, reason} ->
      PubSub.broadcast("crf_search", {:error, video_id, reason})
      :telemetry.execute([:crf_search, :failed], %{reason: reason})
  end
end
```

### Summary: Right Tool for Right Job

| Use Case | Tool | Why |
|----------|------|-----|
| **Real-time UI updates** | PubSub | Immediate, ordered, direct |
| **Metrics/dashboards** | Telemetry | Async collection, aggregation |
| **Error tracking** | Telemetry | Structured data, external tools |
| **Performance monitoring** | Telemetry | Historical analysis |
| **Business intelligence** | Telemetry | Data pipeline to analytics |

**The key insight**: Use telemetry for what it's designed for (observability), use PubSub for what we actually need (real-time UI synchronization).