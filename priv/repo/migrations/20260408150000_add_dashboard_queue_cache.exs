defmodule Reencodarr.Repo.Migrations.AddDashboardQueueCache do
  use Ecto.Migration

  def up do
    alter table(:dashboard_stats_cache) do
      add :encoding_queue_count, :integer, null: false, default: 0
    end

    execute("""
    UPDATE dashboard_stats_cache
    SET encoding_queue_count = (
      SELECT COUNT(*)
      FROM videos
      WHERE state = 'crf_searched' AND chosen_vmaf_id IS NOT NULL
    )
    WHERE id = 1
    """)

    create table(:dashboard_queue_cache) do
      add :queue_type, :text, null: false
      add :video_id, references(:videos, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :priority, :integer, null: false, default: 0
      add :bitrate, :integer, null: false, default: 0
      add :size, :integer, null: false, default: 0
      add :savings, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime
      add :updated_at, :utc_datetime
    end

    create index(:dashboard_queue_cache, [:queue_type])
    create unique_index(:dashboard_queue_cache, [:queue_type, :video_id])

    execute(refresh_analyzer_cache_sql())
    execute(refresh_crf_searcher_cache_sql())
    execute(refresh_encoder_cache_sql())

    execute(stats_encoding_count_trigger_sql("insert"))
    execute(stats_encoding_count_trigger_sql("update"))
    execute(stats_encoding_count_trigger_sql("delete"))

    execute(video_queue_triggers_sql("insert"))
    execute(video_queue_triggers_sql("update"))
    execute(video_queue_triggers_sql("delete"))
    execute(vmaf_queue_triggers_sql("insert"))
    execute(vmaf_queue_triggers_sql("update"))
    execute(vmaf_queue_triggers_sql("delete"))
  end

  def down do
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_encoding_queue_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_encoding_queue_update")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_encoding_queue_delete")

    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_videos_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_videos_update")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_videos_delete")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_vmafs_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_vmafs_update")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_vmafs_delete")

    drop_if_exists index(:dashboard_queue_cache, [:queue_type, :video_id])
    drop_if_exists index(:dashboard_queue_cache, [:queue_type])
    drop table(:dashboard_queue_cache)

    alter table(:dashboard_stats_cache) do
      remove :encoding_queue_count
    end
  end

  defp stats_encoding_count_trigger_sql(action) do
    update_expression =
      case action do
        "insert" ->
          "encoding_queue_count = encoding_queue_count + CASE WHEN NEW.state = 'crf_searched' AND NEW.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END"

        "update" ->
          """
          encoding_queue_count =
            encoding_queue_count
            - CASE WHEN OLD.state = 'crf_searched' AND OLD.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END
            + CASE WHEN NEW.state = 'crf_searched' AND NEW.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END
          """

        "delete" ->
          "encoding_queue_count = encoding_queue_count - CASE WHEN OLD.state = 'crf_searched' AND OLD.chosen_vmaf_id IS NOT NULL THEN 1 ELSE 0 END"
      end

    """
    CREATE TRIGGER dashboard_stats_cache_encoding_queue_#{action}
    AFTER #{String.upcase(action)} ON videos
    BEGIN
      UPDATE dashboard_stats_cache
      SET
        #{update_expression}
      WHERE id = 1;
    END
    """
  end

  defp video_queue_triggers_sql(action) do
    """
    CREATE TRIGGER dashboard_queue_cache_videos_#{action}
    AFTER #{String.upcase(action)} ON videos
    BEGIN
      #{refresh_analyzer_cache_sql()}
      #{refresh_crf_searcher_cache_sql()}
      #{refresh_encoder_cache_sql()}
    END
    """
  end

  defp vmaf_queue_triggers_sql(action) do
    """
    CREATE TRIGGER dashboard_queue_cache_vmafs_#{action}
    AFTER #{String.upcase(action)} ON vmafs
    BEGIN
      #{refresh_encoder_cache_sql()}
    END
    """
  end

  defp refresh_analyzer_cache_sql do
    refresh_queue_cache_sql("analyzer", analyzer_queue_select_sql())
  end

  defp refresh_crf_searcher_cache_sql do
    refresh_queue_cache_sql("crf_searcher", crf_searcher_queue_select_sql())
  end

  defp refresh_encoder_cache_sql do
    refresh_queue_cache_sql("encoder", encoder_queue_select_sql())
  end

  defp refresh_queue_cache_sql(queue_type, select_sql) do
    """
    DELETE FROM dashboard_queue_cache WHERE queue_type = '#{queue_type}';
    INSERT INTO dashboard_queue_cache (
      queue_type, video_id, path, priority, bitrate, size, savings, inserted_at, updated_at
    )
    #{select_sql}
    """
  end

  defp analyzer_queue_select_sql do
    """
    SELECT
      'analyzer',
      id,
      path,
      COALESCE(priority, 0),
      COALESCE(bitrate, 0),
      COALESCE(size, 0),
      0,
      inserted_at,
      updated_at
    FROM videos
    WHERE state = 'needs_analysis'
    ORDER BY priority DESC, size DESC, inserted_at DESC, updated_at DESC
    LIMIT 5;
    """
  end

  defp crf_searcher_queue_select_sql do
    """
    SELECT
      'crf_searcher',
      id,
      path,
      COALESCE(priority, 0),
      COALESCE(bitrate, 0),
      COALESCE(size, 0),
      0,
      inserted_at,
      updated_at
    FROM videos
    WHERE state = 'analyzed'
    ORDER BY priority DESC, bitrate DESC, size DESC, updated_at ASC
    LIMIT 5;
    """
  end

  defp encoder_queue_select_sql do
    """
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
