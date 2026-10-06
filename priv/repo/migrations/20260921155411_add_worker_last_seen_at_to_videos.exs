defmodule Reencodarr.Repo.Migrations.AddWorkerLastSeenAtToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :worker_last_seen_at, :utc_datetime_usec
    end

    create index(:videos, [:state, :worker_last_seen_at])
  end
end
