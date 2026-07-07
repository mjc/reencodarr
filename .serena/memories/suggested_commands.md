# Suggested Commands

- `nix develop -c mix setup` installs deps, creates/migrates DB, and builds assets.
- `nix develop -c mix test` runs the full test suite.
- `nix develop -c mix test path/to/test.exs` runs focused tests.
- `nix develop -c mix compile --warnings-as-errors` catches compile regressions.
- `nix develop -c mix credo --strict` runs lint.
- `nix develop -c mix format` formats; `nix develop -c mix format --check-formatted` verifies formatting.
- `bin/rpc 'Reencodarr.Diagnostics.status()'` and sibling diagnostics helpers inspect the running system.