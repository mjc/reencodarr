defmodule Reencodarr.Repo.Migrations.AddVideoState do
  use Ecto.Migration

  def up do
    # Create enum type for video processing states
    execute(
      "CREATE TYPE video_state AS ENUM ('needs_analysis', 'analyzed', 'crf_searching', 'crf_searched', 'encoding', 'encoded', 'failed')"
    )

    # Add state column with default based on current data
    alter table(:videos) do
      add :state, :video_state
    end

    # Set initial states based on existing data
    execute("""
    UPDATE videos SET state = CASE
      WHEN failed = true THEN 'failed'::video_state
      WHEN reencoded = true THEN 'encoded'::video_state
      WHEN bitrate IS NULL OR width IS NULL OR height IS NULL OR duration IS NULL OR duration <= 0
           OR (video_codecs IS NULL OR array_length(video_codecs, 1) = 0)
           OR ((audio_codecs IS NULL OR array_length(audio_codecs, 1) = 0) AND (audio_count IS NULL OR audio_count > 0))
           THEN 'needs_analysis'::video_state
      WHEN EXISTS (SELECT 1 FROM vmafs WHERE video_id = videos.id AND chosen = true) THEN 'crf_searched'::video_state
      WHEN EXISTS (SELECT 1 FROM vmafs WHERE video_id = videos.id) THEN 'crf_searching'::video_state
      ELSE 'analyzed'::video_state
    END
    """)

    # Make state column NOT NULL after setting initial values
    alter table(:videos) do
      modify :state, :video_state, null: false
    end

    # Add index for efficient state-based queries
    create index(:videos, [:state])
    create index(:videos, [:state, :size])
    create index(:videos, [:state, :updated_at])
  end

  def down do
    alter table(:videos) do
      remove :state
    end

    execute("DROP TYPE video_state")
  end
end
