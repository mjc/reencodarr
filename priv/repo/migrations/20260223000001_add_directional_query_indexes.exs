defmodule Reencodarr.Repo.Migrations.AddDirectionalQueryIndexes do
  use Ecto.Migration

  @moduledoc """
  Replace uni-directional indexes with properly ordered ones matching actual query patterns.

  SQLite can traverse an index in reverse (all DESC), but cannot handle mixed ASC/DESC
  within a single index scan. This forces temp B-tree sorts on large result sets.

  For example, `videos_for_crf_search` queries 57K+ analyzed videos with
  ORDER BY bitrate DESC, size DESC, updated_at ASC — the old all-ASC index
  couldn't avoid sorting.
  """

  def up do
    # Drop old indexes that have wrong (all-ASC) sort directions
    drop_if_exists index(:videos, [:state, :bitrate, :size, :updated_at])
    drop_if_exists index(:vmafs, [:chosen, :savings])

    # CRF search queue: WHERE state = ? ORDER BY bitrate DESC, size DESC, updated_at ASC
    execute """
    CREATE INDEX videos_crf_search_queue_index
    ON videos(state, bitrate DESC, size DESC, updated_at ASC)
    """

    # Analysis queue: WHERE state = ? ORDER BY size DESC, inserted_at DESC, updated_at DESC
    execute """
    CREATE INDEX videos_analysis_queue_index
    ON videos(state, size DESC, inserted_at DESC, updated_at DESC)
    """

    # Encoding queue: WHERE chosen = ? ORDER BY savings DESC
    execute """
    CREATE INDEX vmafs_encoding_queue_index
    ON vmafs(chosen, savings DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS videos_crf_search_queue_index"
    execute "DROP INDEX IF EXISTS videos_analysis_queue_index"
    execute "DROP INDEX IF EXISTS vmafs_encoding_queue_index"

    # Restore original all-ASC indexes
    create index(:videos, [:state, :bitrate, :size, :updated_at])
    create index(:vmafs, [:chosen, :savings])
  end
end
