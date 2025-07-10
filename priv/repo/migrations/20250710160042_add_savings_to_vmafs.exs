defmodule Reencodarr.Repo.Migrations.AddSavingsToVmafs do
  use Ecto.Migration

  def up do
    alter table(:vmafs) do
      add :savings, :bigint
    end

    # Backfill savings for existing records
    execute """
    UPDATE vmafs
    SET savings = CASE
      WHEN percent IS NOT NULL AND percent > 0
      THEN ROUND((100 - percent) / 100.0 * videos.size)
      ELSE NULL
    END
    FROM videos
    WHERE vmafs.video_id = videos.id
    AND vmafs.savings IS NULL
    """
  end

  def down do
    alter table(:vmafs) do
      remove :savings
    end
  end
end
