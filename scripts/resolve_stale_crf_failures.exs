#!/usr/bin/env elixir
# Resolves stale intermediate crf_search failures, keeping only the most recent
# per video. Run via: bin/rpc 'Code.eval_file("scripts/resolve_stale_crf_failures.exs")'

import Ecto.Query
alias Reencodarr.{Repo, Media.VideoFailure}

# Find the max (most recent) failure ID per video for unresolved crf_search failures
max_ids_subquery =
  from f in VideoFailure,
    where: f.failure_stage == :crf_search and f.resolved == false,
    group_by: f.video_id,
    select: max(f.id)

# Resolve everything that is NOT the most recent failure for its video
now = DateTime.utc_now()

{count, _} =
  from(f in VideoFailure,
    where:
      f.failure_stage == :crf_search and f.resolved == false and
        f.id not in subquery(max_ids_subquery),
    update: [set: [resolved: true, resolved_at: ^now]]
  )
  |> Repo.update_all([])

IO.puts("Resolved #{count} stale intermediate crf_search failures")
