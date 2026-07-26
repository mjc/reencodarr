defmodule Reencodarr.Repo.Migrations.AddWorkerTerminalClaimToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :worker_terminal_claimed_at, :utc_datetime_usec
    end

    create index(:videos, [:worker_attempt_id, :worker_terminal_claimed_at])
  end
end
