defmodule Reencodarr.Repo.Migrations.MaintainEncoderDashboardQueueCache do
  use Ecto.Migration

  @video_insert_trigger "dashboard_queue_cache_encoder_videos_insert"
  @video_update_trigger "dashboard_queue_cache_encoder_videos_update"
  @video_delete_trigger "dashboard_queue_cache_encoder_videos_delete"
  @vmaf_update_trigger "dashboard_queue_cache_encoder_vmafs_update"

  def up do
    drop_triggers()
    execute(refresh_encoder_cache_sql())

    execute("""
    CREATE TRIGGER #{@video_insert_trigger}
    AFTER INSERT ON videos
    WHEN NEW.state = 'crf_searched' AND NEW.chosen_vmaf_id IS NOT NULL
    BEGIN
      #{refresh_encoder_cache_sql()}
    END
    """)

    execute("""
    CREATE TRIGGER #{@video_update_trigger}
    AFTER UPDATE OF state, chosen_vmaf_id, priority, path ON videos
    WHEN
      (OLD.state = 'crf_searched' AND OLD.chosen_vmaf_id IS NOT NULL)
      OR
      (NEW.state = 'crf_searched' AND NEW.chosen_vmaf_id IS NOT NULL)
    BEGIN
      #{refresh_encoder_cache_sql()}
    END
    """)

    execute("""
    CREATE TRIGGER #{@video_delete_trigger}
    AFTER DELETE ON videos
    WHEN OLD.state = 'crf_searched' AND OLD.chosen_vmaf_id IS NOT NULL
    BEGIN
      #{refresh_encoder_cache_sql()}
    END
    """)

    execute("""
    CREATE TRIGGER #{@vmaf_update_trigger}
    AFTER UPDATE OF savings ON vmafs
    WHEN EXISTS (
      SELECT 1
      FROM videos
      WHERE chosen_vmaf_id = NEW.id AND state = 'crf_searched'
    )
    BEGIN
      #{refresh_encoder_cache_sql()}
    END
    """)
  end

  def down do
    drop_triggers()
  end

  defp drop_triggers do
    for trigger <- [
          @video_insert_trigger,
          @video_update_trigger,
          @video_delete_trigger,
          @vmaf_update_trigger
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger}")
    end
  end

  defp refresh_encoder_cache_sql do
    """
    DELETE FROM dashboard_queue_cache WHERE queue_type = 'encoder';
    INSERT INTO dashboard_queue_cache (
      queue_type, video_id, path, priority, bitrate, size, savings, inserted_at, updated_at
    )
    SELECT
      'encoder',
      vid.id,
      vid.path,
      COALESCE(vid.priority, 0),
      COALESCE(vid.bitrate, 0),
      COALESCE(vid.size, 0),
      COALESCE(v.savings, 0),
      vid.inserted_at,
      vid.updated_at
    FROM videos AS vid
    JOIN vmafs AS v ON vid.chosen_vmaf_id = v.id
    WHERE vid.state = 'crf_searched'
    ORDER BY vid.priority DESC, v.savings DESC, vid.updated_at DESC
    LIMIT 5;
    """
  end
end
