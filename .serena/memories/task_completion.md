# Task Completion

- Prefer focused tests while iterating, then run broader gates when practical.
- Standard finish gates: `devenv shell -- mix test`, `devenv shell -- mix compile --warnings-as-errors`, `devenv shell -- mix credo --strict`, and `devenv shell -- mix format --check-formatted`.
- Run `devenv shell -- mix format` before committing Elixir changes if formatting may have changed.
- For live runtime/debug claims, verify with `bin/rpc` diagnostics rather than inferring from source.
