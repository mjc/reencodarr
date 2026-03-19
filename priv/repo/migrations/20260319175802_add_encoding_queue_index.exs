defmodule Reencodarr.Repo.Migrations.AddEncodingQueueIndex do
  use Ecto.Migration

  def up do
    # Covering index for encoding queue (videos ready for encoding with state filter)
    # Helps with filtering and ordering by priority/updated_at before joining to vmafs
    execute("""
    CREATE INDEX videos_encoding_queue_index
    ON videos (state, priority DESC, updated_at DESC)
    WHERE state = 'crf_searched'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS videos_encoding_queue_index")
  end
end
