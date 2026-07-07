# Tech Stack

- Elixir `>= 1.20.0 and < 1.21.0` Phoenix app.
- Phoenix `~> 1.8.8`, LiveView `~> 1.2.5`, Bandit `~> 1.12`.
- SQLite through `ecto_sqlite3`/`exqlite`; Ecto SQL `~> 3.14`.
- Uses Nix dev shell for repo commands: `nix develop -c ...`.
- Assets use Tailwind package `~> 0.5.1` and esbuild `~> 0.10` via Mix aliases.
- Test helpers include ExUnit, ConnCase/DataCase, StreamData, Floki/LazyHTML, and meck where existing tests mock external commands.