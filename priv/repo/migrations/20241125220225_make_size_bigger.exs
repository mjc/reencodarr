defmodule Reencodarr.Repo.Migrations.MakeSizeBigger do
  use Ecto.Migration

  def change do
    # SQLite doesn't support ALTER COLUMN - INTEGER can handle large values
    # This migration is effectively a no-op for SQLite
  end
end
