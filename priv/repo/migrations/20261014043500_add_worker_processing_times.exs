defmodule Reencodarr.Repo.Migrations.AddWorkerProcessingTimes do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :crf_search_seconds, :float
      add :encode_seconds, :float
    end

    execute(
      """
      CREATE TABLE worker_job_timings (
        job_id TEXT PRIMARY KEY NOT NULL,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        job_type TEXT NOT NULL CHECK(job_type IN ('crf_search', 'encode')),
        worker_id TEXT NOT NULL,
        active_milliseconds INTEGER NOT NULL DEFAULT 0 CHECK(active_milliseconds >= 0),
        finalization_milliseconds INTEGER NOT NULL DEFAULT 0 CHECK(finalization_milliseconds >= 0),
        finalized INTEGER NOT NULL DEFAULT 0 CHECK(finalized IN (0, 1))
      )
      """,
      "DROP TABLE worker_job_timings"
    )

    create index(:worker_job_timings, [:video_id])
  end
end
