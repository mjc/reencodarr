# Reencodarr AI Instructions

## Purpose
- Reencodarr is an Elixir/Phoenix app for bulk AV1 transcoding with `ab-av1`.
- It syncs media from Sonarr/Radarr, analyzes files, performs CRF search, encodes, and updates the dashboard/live system state.

## Keep This File Tight
- Prefer short, durable instructions over architecture essays.
- If guidance is duplicated elsewhere, keep the shorter version here and delete the duplicate.
- Do not leave speculative or historical notes that are no longer true.

## Core Workflow
- Sync discovers or updates media from Sonarr/Radarr.
- Analyzer extracts metadata with MediaInfo.
- CRF search chooses a quality-targeted CRF.
- Encoder performs the final encode.
- Dashboard and diagnostics reflect live pipeline state.

## Commands
- `mix setup` — install deps, create/migrate DB, build assets.
- `mix test` — run the full test suite. Prefer the full suite over targeted tests before finishing work.
- `mix compile --warnings-as-errors` — catch compile regressions.
- `mix credo --strict` — required lint pass.
- `mix format` / `mix format --check-formatted` — formatting.
- `mix setup_precommit` — install the repo git hooks.

## Live Debugging
- Prefer `bin/rpc` for inspecting the running system; do not guess.
- Useful commands:
  - `bin/rpc 'Reencodarr.Diagnostics.status()'`
  - `bin/rpc 'Reencodarr.Diagnostics.video(123)'`
  - `bin/rpc 'Reencodarr.Diagnostics.find("name")'`
  - `bin/rpc 'Reencodarr.Diagnostics.failures()'`
  - `bin/rpc 'Reencodarr.Diagnostics.queues()'`
  - `bin/rpc 'Reencodarr.Diagnostics.processes()'`
  - `bin/rpc 'Reencodarr.Diagnostics.stuck()'`
  - `bin/rpc 'Reencodarr.Diagnostics.video_args(123)'`
- Failures include `system_context`; read it before changing code.

## Architecture Notes
- Database is SQLite. Keep SQLite tuning centralized in `config/config.exs`; do not reintroduce per-env overrides for those pragmas.
- Broadway pipelines exist for analyzer, CRF searcher, and encoder.
- Producers should check worker availability before dispatching work.
- Test environment disables Broadway-based workers/supervisors that would interfere with sandboxed tests.

## State and Data Rules
- Video states are:
  - `:needs_analysis`
  - `:analyzing`
  - `:analyzed`
  - `:crf_searching`
  - `:crf_searched`
  - `:encoding`
  - `:encoded`
  - `:failed`
- Use `VideoStateMachine` helpers for transitions; do not hand-roll state changes if a state-machine function already exists.
- Treat `:encoded` as protected during sync. Sync must not reset encoded state or discard chosen VMAF/original-size data.
- If sync metadata changes invalidate CRF results, only reset videos that are not already encoded.

## Sync Rules
- Sonarr/Radarr sync should avoid unnecessary DB work where possible, but must still detect replaced files.
- `service_id` on videos represents the source file identifier and is useful for change detection.
- Be careful with shortcuts based only on parent-item timestamps; replacements can happen without the parent item looking new.

## Parsing and Encoding
- `Reencodarr.AbAv1.OutputParser` is the single parser for ab-av1 output.
- Support both abbreviated ETA formats (`1h 23m`, `45s`) and word-based formats where relevant.
- Keep encode and CRF-search parsing behavior aligned through shared parser logic instead of duplicating regexes.
- `Reencodarr.Rules.build_args/4` is the central place for encode/CRF-search argument construction.

## External Services
- Service clients live under `lib/reencodarr/services/`.
- Follow the existing `CarReq` pattern with retries and fuse/circuit-breaker behavior.
- Config records use `service_type`, `url`, `api_key`, `enabled`, and `last_synced_at`.

## Testing Guidance
- Prefer existing fixtures/helpers in `test/support/fixtures.ex`.
- Use `meck` where the current test suite already uses it for external command mocking.
- When changing sync, parser, or state-machine behavior, add or update tests near the affected module.

## File/Module Pointers
- `lib/reencodarr/sync.ex` — Sonarr/Radarr sync and batch upserts.
- `lib/reencodarr/media/video_upsert.ex` — guarded upsert logic, bitrate/VMAF handling.
- `lib/reencodarr/media/video_state_machine.ex` — valid state transitions.
- `lib/reencodarr/ab_av1/output_parser.ex` — shared ab-av1 output parsing.
- `lib/reencodarr/diagnostics.ex` — `bin/rpc` live inspection surface.
- `.iex.exs` — local console helpers.

## Practical Preference
- For this repo, concise current instructions are better than exhaustive documentation in instruction files.
