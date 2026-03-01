defmodule Reencodarr.Repo.Migrations.MoveChosenToVideo do
  use Ecto.Migration

  def up do
    # 1. Add chosen_vmaf_id to videos
    alter table(:videos) do
      add :chosen_vmaf_id, references(:vmafs, on_delete: :nilify_all)
    end

    create index(:videos, [:chosen_vmaf_id])

    # 2. Backfill from existing chosen vmafs
    execute """
    UPDATE videos SET chosen_vmaf_id = (
      SELECT id FROM vmafs
      WHERE vmafs.video_id = videos.id AND vmafs.chosen = 1
      LIMIT 1
    )
    """

    # 3. Drop indexes that reference chosen on vmafs
    drop_if_exists index(:vmafs, [:chosen, :video_id], name: :vmafs_chosen_video_id_index)

    execute "DROP INDEX IF EXISTS vmafs_encoding_queue_index"

    # 4. Recreate encoding queue index without chosen
    execute """
    CREATE INDEX vmafs_encoding_queue_index ON vmafs(savings DESC)
    """

    # Note: chosen column left as dead column on vmafs table.
    # SQLite's DROP COLUMN has limitations with indexes referencing the column.
    # The schema no longer references it, so it's harmless.
  end

  def down do
    # 1. Backfill chosen from video.chosen_vmaf_id (column still exists as dead column)
    execute """
    UPDATE vmafs SET chosen = 0
    """

    execute """
    UPDATE vmafs SET chosen = 1
    WHERE id IN (SELECT chosen_vmaf_id FROM videos WHERE chosen_vmaf_id IS NOT NULL)
    """

    # 2. Restore old indexes
    create index(:vmafs, [:chosen, :video_id])

    execute "DROP INDEX IF EXISTS vmafs_encoding_queue_index"

    execute """
    CREATE INDEX vmafs_encoding_queue_index ON vmafs(chosen, savings DESC)
    """

    # 3. Remove chosen_vmaf_id from videos
    drop index(:videos, [:chosen_vmaf_id])

    alter table(:videos) do
      remove :chosen_vmaf_id
    end
  end
end
