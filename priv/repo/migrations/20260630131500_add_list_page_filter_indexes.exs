defmodule Reencodarr.Repo.Migrations.AddListPageFilterIndexes do
  use Ecto.Migration

  def up do
    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS bad_file_issues_search USING fts5(
      issue_kind,
      classification,
      manual_reason,
      manual_note,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """

    execute """
    INSERT INTO bad_file_issues_search(rowid, issue_kind, classification, manual_reason, manual_note)
    SELECT id,
           COALESCE(issue_kind, ''),
           COALESCE(classification, ''),
           COALESCE(manual_reason, ''),
           COALESCE(manual_note, '')
    FROM bad_file_issues
    WHERE id NOT IN (SELECT rowid FROM bad_file_issues_search)
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS bad_file_issues_search_insert
    AFTER INSERT ON bad_file_issues
    BEGIN
      INSERT INTO bad_file_issues_search(rowid, issue_kind, classification, manual_reason, manual_note)
      VALUES (
        NEW.id,
        COALESCE(NEW.issue_kind, ''),
        COALESCE(NEW.classification, ''),
        COALESCE(NEW.manual_reason, ''),
        COALESCE(NEW.manual_note, '')
      );
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS bad_file_issues_search_delete
    AFTER DELETE ON bad_file_issues
    BEGIN
      DELETE FROM bad_file_issues_search WHERE rowid = OLD.id;
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS bad_file_issues_search_update
    AFTER UPDATE ON bad_file_issues
    BEGIN
      DELETE FROM bad_file_issues_search WHERE rowid = OLD.id;
      INSERT INTO bad_file_issues_search(rowid, issue_kind, classification, manual_reason, manual_note)
      VALUES (
        NEW.id,
        COALESCE(NEW.issue_kind, ''),
        COALESCE(NEW.classification, ''),
        COALESCE(NEW.manual_reason, ''),
        COALESCE(NEW.manual_note, '')
      );
    END;
    """

    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS video_failures_search USING fts5(
      video_id UNINDEXED,
      failure_code,
      failure_message,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """

    execute """
    INSERT INTO video_failures_search(rowid, video_id, failure_code, failure_message)
    SELECT id,
           video_id,
           COALESCE(failure_code, ''),
           COALESCE(failure_message, '')
    FROM video_failures
    WHERE id NOT IN (SELECT rowid FROM video_failures_search)
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS video_failures_search_insert
    AFTER INSERT ON video_failures
    BEGIN
      INSERT INTO video_failures_search(rowid, video_id, failure_code, failure_message)
      VALUES (
        NEW.id,
        NEW.video_id,
        COALESCE(NEW.failure_code, ''),
        COALESCE(NEW.failure_message, '')
      );
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS video_failures_search_delete
    AFTER DELETE ON video_failures
    BEGIN
      DELETE FROM video_failures_search WHERE rowid = OLD.id;
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS video_failures_search_update
    AFTER UPDATE ON video_failures
    BEGIN
      DELETE FROM video_failures_search WHERE rowid = OLD.id;
      INSERT INTO video_failures_search(rowid, video_id, failure_code, failure_message)
      VALUES (
        NEW.id,
        NEW.video_id,
        COALESCE(NEW.failure_code, ''),
        COALESCE(NEW.failure_message, '')
      );
    END;
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_service_updated_at_desc_index
    ON videos(service_type, updated_at DESC, id DESC)
    WHERE service_type IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_state_service_updated_at_desc_index
    ON videos(state, service_type, updated_at DESC, id DESC)
    WHERE service_type IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_sdr_updated_at_desc_index
    ON videos(updated_at DESC, id DESC)
    WHERE hdr IS NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_hdr_updated_at_desc_index
    ON videos(updated_at DESC, id DESC)
    WHERE hdr IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_state_sdr_updated_at_desc_index
    ON videos(state, updated_at DESC, id DESC)
    WHERE hdr IS NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_state_hdr_updated_at_desc_index
    ON videos(state, updated_at DESC, id DESC)
    WHERE hdr IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_service_sdr_updated_at_desc_index
    ON videos(service_type, updated_at DESC, id DESC)
    WHERE hdr IS NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_service_hdr_updated_at_desc_index
    ON videos(service_type, updated_at DESC, id DESC)
    WHERE hdr IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_state_service_sdr_updated_at_desc_index
    ON videos(state, service_type, updated_at DESC, id DESC)
    WHERE hdr IS NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_state_service_hdr_updated_at_desc_index
    ON videos(state, service_type, updated_at DESC, id DESC)
    WHERE hdr IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_path_sort_index
    ON videos(path, id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_size_sort_index
    ON videos(size, id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_width_sort_index
    ON videos(width, id)
    WHERE width IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_bitrate_sort_index
    ON videos(bitrate, id)
    WHERE bitrate IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS bad_file_issues_status_kind_updated_at_desc_index
    ON bad_file_issues(status, issue_kind, updated_at DESC, id DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS bad_file_issues_resolved_status_kind_updated_at_index
    ON bad_file_issues(status, issue_kind, updated_at DESC, id ASC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS bad_file_issues_status_inserted_at_index
    ON bad_file_issues(status, inserted_at ASC, id ASC, video_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS bad_file_issues_video_status_updated_at_desc_index
    ON bad_file_issues(video_id, status, updated_at DESC, id DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS video_failures_unresolved_filter_video_index
    ON video_failures(resolved, failure_stage, failure_category, video_id)
    WHERE resolved = 0
    """

    execute """
    CREATE INDEX IF NOT EXISTS video_failures_video_unresolved_filter_recent_index
    ON video_failures(video_id, resolved, failure_stage, failure_category, inserted_at DESC)
    WHERE resolved = 0
    """

    execute """
    CREATE INDEX IF NOT EXISTS videos_failed_updated_at_desc_index
    ON videos(updated_at DESC, id DESC)
    WHERE state = 'failed'
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS video_failures_search_update"
    execute "DROP TRIGGER IF EXISTS video_failures_search_delete"
    execute "DROP TRIGGER IF EXISTS video_failures_search_insert"
    execute "DROP TABLE IF EXISTS video_failures_search"
    execute "DROP TRIGGER IF EXISTS bad_file_issues_search_update"
    execute "DROP TRIGGER IF EXISTS bad_file_issues_search_delete"
    execute "DROP TRIGGER IF EXISTS bad_file_issues_search_insert"
    execute "DROP TABLE IF EXISTS bad_file_issues_search"
    execute "DROP INDEX IF EXISTS videos_failed_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS video_failures_video_unresolved_filter_recent_index"
    execute "DROP INDEX IF EXISTS video_failures_unresolved_filter_video_index"
    execute "DROP INDEX IF EXISTS bad_file_issues_video_status_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS bad_file_issues_status_inserted_at_index"
    execute "DROP INDEX IF EXISTS bad_file_issues_resolved_status_kind_updated_at_index"
    execute "DROP INDEX IF EXISTS bad_file_issues_status_kind_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_bitrate_sort_index"
    execute "DROP INDEX IF EXISTS videos_width_sort_index"
    execute "DROP INDEX IF EXISTS videos_size_sort_index"
    execute "DROP INDEX IF EXISTS videos_path_sort_index"
    execute "DROP INDEX IF EXISTS videos_state_service_hdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_state_service_sdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_service_hdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_service_sdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_state_hdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_state_sdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_hdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_sdr_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_state_service_updated_at_desc_index"
    execute "DROP INDEX IF EXISTS videos_service_updated_at_desc_index"
  end
end
