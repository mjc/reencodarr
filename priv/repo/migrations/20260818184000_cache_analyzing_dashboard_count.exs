defmodule Reencodarr.Repo.Migrations.CacheAnalyzingDashboardCount do
  use Ecto.Migration

  def up do
    alter table(:dashboard_stats_cache) do
      add :analyzing, :integer, null: false, default: 0
    end

    execute("""
    UPDATE dashboard_stats_cache
    SET analyzing = (SELECT COUNT(*) FROM videos WHERE state = 'analyzing')
    WHERE id = 1
    """)

    execute("""
    CREATE TRIGGER dashboard_stats_cache_analyzing_insert
    AFTER INSERT ON videos WHEN NEW.state = 'analyzing'
    BEGIN
      UPDATE dashboard_stats_cache SET analyzing = analyzing + 1 WHERE id = 1;
    END
    """)

    execute("""
    CREATE TRIGGER dashboard_stats_cache_analyzing_update
    AFTER UPDATE OF state ON videos WHEN OLD.state = 'analyzing' OR NEW.state = 'analyzing'
    BEGIN
      UPDATE dashboard_stats_cache
      SET analyzing = analyzing
        - CASE WHEN OLD.state = 'analyzing' THEN 1 ELSE 0 END
        + CASE WHEN NEW.state = 'analyzing' THEN 1 ELSE 0 END
      WHERE id = 1;
    END
    """)

    execute("""
    CREATE TRIGGER dashboard_stats_cache_analyzing_delete
    AFTER DELETE ON videos WHEN OLD.state = 'analyzing'
    BEGIN
      UPDATE dashboard_stats_cache SET analyzing = analyzing - 1 WHERE id = 1;
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_analyzing_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_analyzing_update")
    execute("DROP TRIGGER IF EXISTS dashboard_stats_cache_analyzing_delete")

    alter table(:dashboard_stats_cache) do
      remove :analyzing
    end
  end
end
