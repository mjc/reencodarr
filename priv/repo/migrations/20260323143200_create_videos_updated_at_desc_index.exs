defmodule Reencodarr.Repo.Migrations.CreateVideosUpdatedAtDescIndex do
  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS videos_updated_at_desc_index
    ON videos(updated_at DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS videos_updated_at_desc_index"
  end
end
