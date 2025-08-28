defmodule Reencodarr.Repo.Migrations.AlterVmafsParamsToTextArray do
  use Ecto.Migration

  def up do
    # SQLite doesn't support ALTER COLUMN type changes
    # With ecto_sqlite3 native array support, {:array, :string} and {:array, :text} are functionally equivalent
    # This migration is effectively a no-op for SQLite
  end

  def down do
    # SQLite doesn't support ALTER COLUMN type changes
    # This migration is effectively a no-op for SQLite
  end
end
