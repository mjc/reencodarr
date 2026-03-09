defmodule Reencodarr.Repo.Migrations.AddAnalyzingState do
  use Ecto.Migration

  def up do
    # SQLite stores enums as strings — no schema change needed.
    # Reset any videos that might be stuck in the new :analyzing state
    # (e.g., from a crash during analysis).
    execute("UPDATE videos SET state = 'needs_analysis' WHERE state = 'analyzing'")
  end

  def down do
    execute("UPDATE videos SET state = 'needs_analysis' WHERE state = 'analyzing'")
  end
end
