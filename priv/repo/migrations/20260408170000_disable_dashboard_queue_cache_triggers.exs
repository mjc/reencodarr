defmodule Reencodarr.Repo.Migrations.DisableDashboardQueueCacheTriggers do
  use Ecto.Migration

  def up do
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_videos_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_videos_update")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_videos_delete")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_vmafs_insert")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_vmafs_update")
    execute("DROP TRIGGER IF EXISTS dashboard_queue_cache_vmafs_delete")
  end

  def down do
    raise "Cannot safely restore dashboard queue cache triggers"
  end
end
