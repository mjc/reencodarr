# Core

- Phoenix app for Reencodarr media transcoding; web modules under `lib/reencodarr_web`, domain modules under `lib/reencodarr`.
- SQLite via `Reencodarr.Repo`; keep DB tuning centralized in `config/config.exs`.
- Broadway/local worker supervisors are disabled in tests via `config :reencodarr, env: :test` and `Application.worker_children/0`.
- Existing app invariants and live-debug commands live in `AGENTS.md`; prefer repo evidence, logs, diagnostics, and tests over guessing.

Related memories: commands in `mem:suggested_commands`, done gates in `mem:task_completion`, style in `mem:conventions`, stack in `mem:tech_stack`.