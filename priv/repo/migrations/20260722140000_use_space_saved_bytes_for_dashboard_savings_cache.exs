defmodule Reencodarr.Repo.Migrations.UseSpaceSavedBytesForDashboardSavingsCache do
  use Ecto.Migration

  def up do
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_videos_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_videos_update")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_videos_delete")

    execute("""
    UPDATE dashboard_stats_cache
    SET encoded_savings_bytes = (
      SELECT COALESCE(SUM(CASE WHEN space_saved_bytes > 0 THEN space_saved_bytes ELSE 0 END), 0)
      FROM videos
    )
    WHERE id = 1
    """)

    execute(video_insert_trigger())
    execute(video_update_trigger())
    execute(video_delete_trigger())
  end

  defp video_insert_trigger do
    """
    CREATE TRIGGER dashboard_stats_cache_videos_insert
    AFTER INSERT ON videos
    BEGIN
      UPDATE dashboard_stats_cache
      SET
        total_videos = total_videos + 1,
        total_size_bytes = total_size_bytes + COALESCE(NEW.size, 0),
        total_duration_seconds = total_duration_seconds + CASE WHEN NEW.duration IS NOT NULL AND NEW.duration > 0 THEN NEW.duration ELSE 0 END,
        duration_count = duration_count + CASE WHEN NEW.duration IS NOT NULL AND NEW.duration > 0 THEN 1 ELSE 0 END,
        needs_analysis = needs_analysis + CASE WHEN NEW.state = 'needs_analysis' THEN 1 ELSE 0 END,
        analyzed = analyzed + CASE WHEN NEW.state = 'analyzed' THEN 1 ELSE 0 END,
        crf_searching = crf_searching + CASE WHEN NEW.state = 'crf_searching' THEN 1 ELSE 0 END,
        crf_searched = crf_searched + CASE WHEN NEW.state = 'crf_searched' THEN 1 ELSE 0 END,
        encoding = encoding + CASE WHEN NEW.state = 'encoding' THEN 1 ELSE 0 END,
        encoded = encoded + CASE WHEN NEW.state = 'encoded' THEN 1 ELSE 0 END,
        failed = failed + CASE WHEN NEW.state = 'failed' THEN 1 ELSE 0 END,
        most_recent_video_update = CASE
          WHEN most_recent_video_update IS NULL OR NEW.updated_at > most_recent_video_update THEN NEW.updated_at
          ELSE most_recent_video_update
        END,
        most_recent_inserted_video = CASE
          WHEN most_recent_inserted_video IS NULL OR NEW.inserted_at > most_recent_inserted_video THEN NEW.inserted_at
          ELSE most_recent_inserted_video
        END,
        chosen_vmafs = chosen_vmafs + CASE WHEN NEW.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END,
        encoded_savings_bytes = encoded_savings_bytes + CASE
          WHEN NEW.space_saved_bytes IS NOT NULL AND NEW.space_saved_bytes > 0 THEN NEW.space_saved_bytes
          ELSE 0
        END,
        predicted_savings_bytes = predicted_savings_bytes + CASE
          WHEN NEW.state != 'encoded' AND NEW.chosen_vmaf_id IS NOT NULL
          THEN COALESCE((SELECT CASE WHEN savings > 0 THEN savings ELSE 0 END FROM vmafs WHERE id = NEW.chosen_vmaf_id), 0)
          ELSE 0
        END
      WHERE id = 1;
    END
    """
  end

  defp video_update_trigger do
    """
    CREATE TRIGGER dashboard_stats_cache_videos_update
    AFTER UPDATE ON videos
    BEGIN
      UPDATE dashboard_stats_cache
      SET
        total_size_bytes = total_size_bytes - COALESCE(OLD.size, 0) + COALESCE(NEW.size, 0),
        total_duration_seconds =
          total_duration_seconds
          - CASE WHEN OLD.duration IS NOT NULL AND OLD.duration > 0 THEN OLD.duration ELSE 0 END
          + CASE WHEN NEW.duration IS NOT NULL AND NEW.duration > 0 THEN NEW.duration ELSE 0 END,
        duration_count =
          duration_count
          - CASE WHEN OLD.duration IS NOT NULL AND OLD.duration > 0 THEN 1 ELSE 0 END
          + CASE WHEN NEW.duration IS NOT NULL AND NEW.duration > 0 THEN 1 ELSE 0 END,
        needs_analysis =
          needs_analysis
          - CASE WHEN OLD.state = 'needs_analysis' THEN 1 ELSE 0 END
          + CASE WHEN NEW.state = 'needs_analysis' THEN 1 ELSE 0 END,
        analyzed =
          analyzed
          - CASE WHEN OLD.state = 'analyzed' THEN 1 ELSE 0 END
          + CASE WHEN NEW.state = 'analyzed' THEN 1 ELSE 0 END,
        crf_searching =
          crf_searching
          - CASE WHEN OLD.state = 'crf_searching' THEN 1 ELSE 0 END
          + CASE WHEN NEW.state = 'crf_searching' THEN 1 ELSE 0 END,
        crf_searched =
          crf_searched
          - CASE WHEN OLD.state = 'crf_searched' THEN 1 ELSE 0 END
          + CASE WHEN NEW.state = 'crf_searched' THEN 1 ELSE 0 END,
        encoding =
          encoding
          - CASE WHEN OLD.state = 'encoding' THEN 1 ELSE 0 END
          + CASE WHEN NEW.state = 'encoding' THEN 1 ELSE 0 END,
        encoded =
          encoded
          - CASE WHEN OLD.state = 'encoded' THEN 1 ELSE 0 END
          + CASE WHEN NEW.state = 'encoded' THEN 1 ELSE 0 END,
        failed =
          failed
          - CASE WHEN OLD.state = 'failed' THEN 1 ELSE 0 END
          + CASE WHEN NEW.state = 'failed' THEN 1 ELSE 0 END,
        most_recent_video_update = CASE
          WHEN most_recent_video_update IS NULL OR NEW.updated_at > most_recent_video_update THEN NEW.updated_at
          ELSE most_recent_video_update
        END,
        most_recent_inserted_video = CASE
          WHEN most_recent_inserted_video IS NULL OR NEW.inserted_at > most_recent_inserted_video THEN NEW.inserted_at
          ELSE most_recent_inserted_video
        END,
        chosen_vmafs =
          chosen_vmafs
          - CASE WHEN OLD.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END
          + CASE WHEN NEW.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END,
        encoded_savings_bytes =
          encoded_savings_bytes
          - CASE
              WHEN OLD.space_saved_bytes IS NOT NULL AND OLD.space_saved_bytes > 0 THEN OLD.space_saved_bytes
              ELSE 0
            END
          + CASE
              WHEN NEW.space_saved_bytes IS NOT NULL AND NEW.space_saved_bytes > 0 THEN NEW.space_saved_bytes
              ELSE 0
            END,
        predicted_savings_bytes =
          predicted_savings_bytes
          - CASE
              WHEN OLD.state != 'encoded' AND OLD.chosen_vmaf_id IS NOT NULL
              THEN COALESCE((SELECT CASE WHEN savings > 0 THEN savings ELSE 0 END FROM vmafs WHERE id = OLD.chosen_vmaf_id), 0)
              ELSE 0
            END
          + CASE
              WHEN NEW.state != 'encoded' AND NEW.chosen_vmaf_id IS NOT NULL
              THEN COALESCE((SELECT CASE WHEN savings > 0 THEN savings ELSE 0 END FROM vmafs WHERE id = NEW.chosen_vmaf_id), 0)
              ELSE 0
            END
      WHERE id = 1;
    END
    """
  end

  defp video_delete_trigger do
    """
    CREATE TRIGGER dashboard_stats_cache_videos_delete
    AFTER DELETE ON videos
    BEGIN
      UPDATE dashboard_stats_cache
      SET
        total_videos = total_videos - 1,
        total_size_bytes = total_size_bytes - COALESCE(OLD.size, 0),
        total_duration_seconds = total_duration_seconds - CASE WHEN OLD.duration IS NOT NULL AND OLD.duration > 0 THEN OLD.duration ELSE 0 END,
        duration_count = duration_count - CASE WHEN OLD.duration IS NOT NULL AND OLD.duration > 0 THEN 1 ELSE 0 END,
        needs_analysis = needs_analysis - CASE WHEN OLD.state = 'needs_analysis' THEN 1 ELSE 0 END,
        analyzed = analyzed - CASE WHEN OLD.state = 'analyzed' THEN 1 ELSE 0 END,
        crf_searching = crf_searching - CASE WHEN OLD.state = 'crf_searching' THEN 1 ELSE 0 END,
        crf_searched = crf_searched - CASE WHEN OLD.state = 'crf_searched' THEN 1 ELSE 0 END,
        encoding = encoding - CASE WHEN OLD.state = 'encoding' THEN 1 ELSE 0 END,
        encoded = encoded - CASE WHEN OLD.state = 'encoded' THEN 1 ELSE 0 END,
        failed = failed - CASE WHEN OLD.state = 'failed' THEN 1 ELSE 0 END,
        chosen_vmafs = chosen_vmafs - CASE WHEN OLD.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END,
        encoded_savings_bytes = encoded_savings_bytes - CASE
          WHEN OLD.space_saved_bytes IS NOT NULL AND OLD.space_saved_bytes > 0 THEN OLD.space_saved_bytes
          ELSE 0
        END,
        predicted_savings_bytes = predicted_savings_bytes - CASE
          WHEN OLD.state != 'encoded' AND OLD.chosen_vmaf_id IS NOT NULL
          THEN COALESCE((SELECT CASE WHEN savings > 0 THEN savings ELSE 0 END FROM vmafs WHERE id = OLD.chosen_vmaf_id), 0)
          ELSE 0
        END
      WHERE id = 1;
    END
    """
  end
end
