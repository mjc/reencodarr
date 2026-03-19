defmodule Reencodarr.Repo.Migrations.UpdateQueueIndexesForPriority do
  use Ecto.Migration

  def up do
    # Drop the simple (state, priority) index — it's now redundant
    drop_if_exists index(:videos, [:state, :priority])

    # Drop stale indexes by name (mixed ASC/DESC, no priority)
    execute("DROP INDEX IF EXISTS videos_crf_search_queue_index")
    execute("DROP INDEX IF EXISTS videos_analysis_queue_index")

    # New covering indexes with priority as leading sort column and partial index clauses
    execute("""
    CREATE INDEX videos_crf_search_queue_index
    ON videos (state, priority DESC, bitrate DESC, size DESC, updated_at ASC)
    WHERE state = 'analyzed'
    """)

    execute("""
    CREATE INDEX videos_analysis_queue_index
    ON videos (state, priority DESC, size DESC, inserted_at DESC, updated_at DESC)
    WHERE state = 'needs_analysis'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS videos_crf_search_queue_index")
    execute("DROP INDEX IF EXISTS videos_analysis_queue_index")

    execute("""
    CREATE INDEX videos_crf_search_queue_index
    ON videos (state, bitrate DESC, size DESC, updated_at ASC)
    """)

    execute("""
    CREATE INDEX videos_analysis_queue_index
    ON videos (state, size DESC, inserted_at DESC, updated_at DESC)
    """)

    create index(:videos, [:state, :priority])
  end
end
