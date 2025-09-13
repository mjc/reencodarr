defmodule Reencodarr.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  def up do
    # Add index on video_codecs for faster AV1 filtering
    # SQLite doesn't support functional indexes on JSON, but we can add covering indexes
    create index(:videos, [:state, :bitrate, :size, :updated_at])

    # Add composite index for VMAF joins with video state
    create index(:vmafs, [:chosen, :video_id])

    # Add index for VMAF savings ordering (used in encoding queue)
    create index(:vmafs, [:chosen, :savings])
  end

  def down do
    drop index(:videos, [:state, :bitrate, :size, :updated_at])
    drop index(:vmafs, [:chosen, :video_id])
    drop index(:vmafs, [:chosen, :savings])
  end
end
