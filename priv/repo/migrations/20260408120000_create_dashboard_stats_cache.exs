defmodule Reencodarr.Repo.Migrations.CreateDashboardStatsCache do
  use Ecto.Migration

  def up do
    create table(:dashboard_stats_cache, primary_key: false) do
      add :id, :integer, primary_key: true
      add :total_videos, :integer, null: false, default: 0
      add :total_size_bytes, :bigint, null: false, default: 0
      add :total_duration_seconds, :float, null: false, default: 0.0
      add :duration_count, :integer, null: false, default: 0
      add :needs_analysis, :integer, null: false, default: 0
      add :analyzed, :integer, null: false, default: 0
      add :crf_searching, :integer, null: false, default: 0
      add :crf_searched, :integer, null: false, default: 0
      add :encoding, :integer, null: false, default: 0
      add :encoded, :integer, null: false, default: 0
      add :failed, :integer, null: false, default: 0
      add :most_recent_video_update, :utc_datetime
      add :most_recent_inserted_video, :utc_datetime
      add :total_vmafs, :integer, null: false, default: 0
      add :chosen_vmafs, :integer, null: false, default: 0
      add :encoded_savings_bytes, :bigint, null: false, default: 0
      add :predicted_savings_bytes, :bigint, null: false, default: 0
    end

    execute("""
    INSERT INTO dashboard_stats_cache (
      id,
      total_videos,
      total_size_bytes,
      total_duration_seconds,
      duration_count,
      needs_analysis,
      analyzed,
      crf_searching,
      crf_searched,
      encoding,
      encoded,
      failed,
      most_recent_video_update,
      most_recent_inserted_video,
      total_vmafs,
      chosen_vmafs,
      encoded_savings_bytes,
      predicted_savings_bytes
    )
    VALUES (
      1,
      COALESCE((SELECT COUNT(*) FROM videos), 0),
      COALESCE((SELECT SUM(COALESCE(size, 0)) FROM videos), 0),
      COALESCE((SELECT SUM(CASE WHEN duration IS NOT NULL AND duration > 0 THEN duration ELSE 0 END) FROM videos), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE duration IS NOT NULL AND duration > 0), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE state = 'needs_analysis'), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE state = 'analyzed'), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE state = 'crf_searching'), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE state = 'crf_searched'), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE state = 'encoding'), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE state = 'encoded'), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE state = 'failed'), 0),
      (SELECT MAX(updated_at) FROM videos),
      (SELECT MAX(inserted_at) FROM videos),
      COALESCE((SELECT COUNT(*) FROM vmafs), 0),
      COALESCE((SELECT COUNT(*) FROM videos WHERE chosen_vmaf_id IS NOT NULL), 0),
      COALESCE((
        SELECT SUM(
          CASE
            WHEN state = 'encoded' AND original_size IS NOT NULL AND original_size > COALESCE(size, 0)
            THEN original_size - COALESCE(size, 0)
            ELSE 0
          END
        )
        FROM videos
      ), 0),
      COALESCE((
        SELECT SUM(
          CASE
            WHEN videos.state != 'encoded' AND videos.chosen_vmaf_id IS NOT NULL AND vmafs.savings > 0
            THEN vmafs.savings
            ELSE 0
          END
        )
        FROM videos
        LEFT JOIN vmafs ON vmafs.id = videos.chosen_vmaf_id
      ), 0)
    )
    """)

    execute(video_insert_trigger())
    execute(video_update_trigger())
    execute(video_delete_trigger())
    execute(vmaf_insert_trigger())
    execute(vmaf_update_trigger())
    execute(vmaf_delete_trigger())
  end

  def down do
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_videos_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_videos_update")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_videos_delete")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_vmafs_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_vmafs_update")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_vmafs_delete")
    drop table(:dashboard_stats_cache)
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
          WHEN NEW.state = 'encoded' AND NEW.original_size IS NOT NULL AND NEW.original_size > COALESCE(NEW.size, 0)
          THEN NEW.original_size - COALESCE(NEW.size, 0)
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
              WHEN OLD.state = 'encoded' AND OLD.original_size IS NOT NULL AND OLD.original_size > COALESCE(OLD.size, 0)
              THEN OLD.original_size - COALESCE(OLD.size, 0)
              ELSE 0
            END
          + CASE
              WHEN NEW.state = 'encoded' AND NEW.original_size IS NOT NULL AND NEW.original_size > COALESCE(NEW.size, 0)
              THEN NEW.original_size - COALESCE(NEW.size, 0)
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
          WHEN OLD.state = 'encoded' AND OLD.original_size IS NOT NULL AND OLD.original_size > COALESCE(OLD.size, 0)
          THEN OLD.original_size - COALESCE(OLD.size, 0)
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

  defp vmaf_insert_trigger do
    """
    CREATE TRIGGER dashboard_stats_cache_vmafs_insert
    AFTER INSERT ON vmafs
    BEGIN
      UPDATE dashboard_stats_cache
      SET
        total_vmafs = total_vmafs + 1,
        predicted_savings_bytes =
          predicted_savings_bytes
          + (
            CASE WHEN NEW.savings IS NOT NULL AND NEW.savings > 0 THEN NEW.savings ELSE 0 END
            * COALESCE((SELECT COUNT(*) FROM videos WHERE chosen_vmaf_id = NEW.id AND state != 'encoded'), 0)
          )
      WHERE id = 1;
    END
    """
  end

  defp vmaf_update_trigger do
    """
    CREATE TRIGGER dashboard_stats_cache_vmafs_update
    AFTER UPDATE ON vmafs
    BEGIN
      UPDATE dashboard_stats_cache
      SET
        predicted_savings_bytes =
          predicted_savings_bytes
          + (
            (
              CASE WHEN NEW.savings IS NOT NULL AND NEW.savings > 0 THEN NEW.savings ELSE 0 END
              - CASE WHEN OLD.savings IS NOT NULL AND OLD.savings > 0 THEN OLD.savings ELSE 0 END
            )
            * COALESCE((SELECT COUNT(*) FROM videos WHERE chosen_vmaf_id = NEW.id AND state != 'encoded'), 0)
          )
      WHERE id = 1;
    END
    """
  end

  defp vmaf_delete_trigger do
    """
    CREATE TRIGGER dashboard_stats_cache_vmafs_delete
    AFTER DELETE ON vmafs
    BEGIN
      UPDATE dashboard_stats_cache
      SET total_vmafs = total_vmafs - 1
      WHERE id = 1;
    END
    """
  end
end
