defmodule Reencodarr.Repo.Migrations.AddWorkerAttemptIdToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :worker_attempt_id, :string
    end

    create index(:videos, [:state, :worker_attempt_id])
  end
end
