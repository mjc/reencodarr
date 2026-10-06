defmodule Reencodarr.Repo.Migrations.AddWorkerAttemptIdToVideoFailures do
  use Ecto.Migration

  def change do
    alter table(:video_failures) do
      add :worker_attempt_id, :string
    end

    create unique_index(:video_failures, [:video_id, :worker_attempt_id])
  end
end
