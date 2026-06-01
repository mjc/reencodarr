# Reencodarr AI Instructions

## Purpose
- Reencodarr is an Elixir/Phoenix app for bulk AV1 transcoding with `ab-av1`.
- It syncs media from Sonarr/Radarr, analyzes files, runs CRF search, encodes, and updates the live dashboard.

## Keep This File Tight
- Prefer short, durable instructions over architecture essays.
- Remove stale notes instead of preserving history here.
- Prefer repo evidence, logs, diagnostics, and tests over guessing.

## Commands
- Use `nix develop -c <command>` for repo commands.
- `nix develop -c mix setup` installs deps, creates/migrates the DB, and builds assets.
- `nix develop -c mix test` runs the full test suite. Prefer the full suite before finishing when practical.
- `nix develop -c mix compile --warnings-as-errors` catches compile regressions.
- `nix develop -c mix credo --strict` is the lint pass.
- `nix develop -c mix format` and `nix develop -c mix format --check-formatted` handle formatting.

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
- Database is SQLite. Keep SQLite tuning centralized in `config/config.exs`.
- Broadway pipelines exist for analyzer, CRF searcher, and encoder.
- Producers should check worker availability before dispatching work.
- Test disables Broadway-based workers/supervisors that interfere with sandboxed tests.

## State and Data Rules
- Video states are `:needs_analysis`, `:analyzing`, `:analyzed`, `:crf_searching`, `:crf_searched`, `:encoding`, `:encoded`, and `:failed`.
- Use `VideoStateMachine` helpers for transitions when one exists.
- Treat `:encoded` as protected during sync. Sync must not reset encoded state or discard chosen VMAF/original-size data.
- If sync metadata changes invalidate CRF results, only reset videos that are not already encoded.

## Sync Rules
- Sonarr/Radarr sync should avoid unnecessary DB work, but must still detect replaced files.
- `service_id` on videos represents the source file identifier and is useful for change detection.
- Do not rely only on parent item timestamps; replacements can happen without the parent item looking new.

## Parsing and Encoding
- `Reencodarr.AbAv1.OutputParser` is the shared parser for `ab-av1` output.
- Keep encode and CRF-search parsing aligned through shared parser logic.
- `Reencodarr.Rules.build_args/4` is the central encode/CRF-search argument builder.

## External Services
- Service clients live under `lib/reencodarr/services/`.
- Follow the existing `CarReq` pattern with retries and fuse/circuit-breaker behavior.
- Config records use `service_type`, `url`, `api_key`, `enabled`, and `last_synced_at`.

## Testing Guidance
- Prefer existing fixtures/helpers in `test/support/fixtures.ex`.
- Use `meck` where the current test suite already uses it for external command mocking.
- When changing sync, parser, state-machine, or LiveView behavior, add or update tests near the affected module.

## File/Module Pointers
- `lib/reencodarr/sync.ex` - Sonarr/Radarr sync and batch upserts.
- `lib/reencodarr/media/video_upsert.ex` - guarded upsert logic, bitrate/VMAF handling.
- `lib/reencodarr/media/video_state_machine.ex` - valid state transitions.
- `lib/reencodarr/ab_av1/output_parser.ex` - shared `ab-av1` output parsing.
- `lib/reencodarr/diagnostics.ex` - `bin/rpc` live inspection surface.
- `.iex.exs` - local console helpers.
