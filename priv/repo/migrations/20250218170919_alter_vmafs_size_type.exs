defmodule Reencodarr.Repo.Migrations.AlterVmafsSizeType do
  use Ecto.Migration

  def up do
    # SQLite doesn't support ALTER COLUMN - TEXT is the default string type
    # This migration is effectively a no-op for SQLite
  end

  def down do
    # SQLite doesn't support ALTER COLUMN - TEXT is the default string type
    # This migration is effectively a no-op for SQLite
  end
end
