defmodule Reencodarr.Repo.Migrations.AddVideoState do
  use Ecto.Migration

  def up do
    # SQLite doesn't support ENUM types, use TEXT column
    alter table(:videos) do
      add :state, :text
    end

    # Set initial states based on existing data (SQLite compatible)
    execute("""
    UPDATE videos SET state = CASE
      WHEN failed = 1 THEN 'failed'
      WHEN reencoded = 1 THEN 'encoded'
      WHEN bitrate IS NULL OR width IS NULL OR height IS NULL OR duration IS NULL OR duration <= 0
           OR video_codecs IS NULL OR json_array_length(video_codecs) = 0
           OR (audio_codecs IS NULL OR json_array_length(audio_codecs) = 0) AND (audio_count IS NULL OR audio_count > 0)
           THEN 'needs_analysis'
      WHEN EXISTS (SELECT 1 FROM vmafs WHERE video_id = videos.id AND chosen = 1) THEN 'crf_searched'
      WHEN EXISTS (SELECT 1 FROM vmafs WHERE video_id = videos.id) THEN 'crf_searching'
      ELSE 'analyzed'
    END
    """)

    # Make state column NOT NULL after setting initial values
    execute("UPDATE videos SET state = 'needs_analysis' WHERE state IS NULL")

    # Add indexes for efficient state-based queries
    create index(:videos, [:state])
    create index(:videos, [:state, :size])
    create index(:videos, [:state, :updated_at])
  end

  def down do
    drop index(:videos, [:state, :updated_at])
    drop index(:videos, [:state, :size])
    drop index(:videos, [:state])

    alter table(:videos) do
      remove :state
    end
  end
end
