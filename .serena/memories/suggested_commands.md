# Suggested Commands

- `devenv shell -- mix setup` installs deps, creates/migrates DB, and builds assets.
- `devenv shell -- mix test` runs the full test suite.
- `devenv shell -- mix test path/to/test.exs` runs focused tests.
- `devenv shell -- mix compile --warnings-as-errors` catches compile regressions.
- `devenv shell -- mix credo --strict` runs lint.
- `devenv shell -- mix format` formats; `devenv shell -- mix format --check-formatted` verifies formatting.
- `bin/rpc 'Reencodarr.Diagnostics.status()'` and sibling diagnostics helpers inspect the running system.
