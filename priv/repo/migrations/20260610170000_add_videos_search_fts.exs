defmodule Reencodarr.Repo.Migrations.AddVideosSearchFts do
  use Ecto.Migration

  def up do
    execute("""
    CREATE VIRTUAL TABLE videos_search USING fts5(
      path,
      title,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """)

    execute("""
    INSERT INTO videos_search(rowid, path, title)
    SELECT id, COALESCE(path, ''), COALESCE(title, '')
    FROM videos
    """)

    execute("""
    CREATE TRIGGER videos_search_insert
    AFTER INSERT ON videos
    BEGIN
      INSERT INTO videos_search(rowid, path, title)
      VALUES (NEW.id, COALESCE(NEW.path, ''), COALESCE(NEW.title, ''));
    END;
    """)

    execute("""
    CREATE TRIGGER videos_search_delete
    AFTER DELETE ON videos
    BEGIN
      DELETE FROM videos_search WHERE rowid = OLD.id;
    END;
    """)

    execute("""
    CREATE TRIGGER videos_search_update
    AFTER UPDATE ON videos
    BEGIN
      DELETE FROM videos_search WHERE rowid = OLD.id;
      INSERT INTO videos_search(rowid, path, title)
      VALUES (NEW.id, COALESCE(NEW.path, ''), COALESCE(NEW.title, ''));
    END;
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS videos_search_update")
    execute("DROP TRIGGER IF EXISTS videos_search_delete")
    execute("DROP TRIGGER IF EXISTS videos_search_insert")
    execute("DROP TABLE IF EXISTS videos_search")
  end
end
