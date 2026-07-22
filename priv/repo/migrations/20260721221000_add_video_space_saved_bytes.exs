defmodule Reencodarr.Repo.Migrations.AddVideoSpaceSavedBytes do
  use Ecto.Migration

  def up do
    alter table(:videos) do
      add :space_saved_bytes, :bigint, null: false, default: 0
    end

    execute("""
    UPDATE videos
    SET space_saved_bytes = CASE
      WHEN state = 'encoded' AND original_size > COALESCE(size, 0) THEN original_size - COALESCE(size, 0)
      ELSE 0
    END
    """)
  end

  def down do
    alter table(:videos) do
      remove :space_saved_bytes
    end
  end
end
