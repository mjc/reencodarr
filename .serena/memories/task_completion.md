# Task Completion

- Prefer focused tests while iterating, then run broader gates when practical.
- Standard finish gates: `nix develop -c mix test`, `nix develop -c mix compile --warnings-as-errors`, `nix develop -c mix credo --strict`, and `nix develop -c mix format --check-formatted`.
- Run `nix develop -c mix format` before committing Elixir changes if formatting may have changed.
- For live runtime/debug claims, verify with `bin/rpc` diagnostics rather than inferring from source.