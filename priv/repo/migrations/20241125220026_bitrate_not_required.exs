defmodule Reencodarr.Repo.Migrations.BitrateNotRequired do
  use Ecto.Migration

  def change do
    # SQLite doesn't support ALTER COLUMN - bitrate is already nullable by default
    # This migration is effectively a no-op for SQLite
  end
end
