defmodule Reencodarr.Repo.Migrations.MakePathLonger do
  use Ecto.Migration

  def up do
    # SQLite doesn't support ALTER COLUMN - TEXT is already the default string type
    # This migration is effectively a no-op for SQLite
  end

  def down do
  end
end
